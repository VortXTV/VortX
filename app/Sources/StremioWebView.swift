import SwiftUI
import WebKit
import os

/// Hosts the live Stremio web UI and bridges stream selections to the native libmpv player.
/// The injected script catches the URL the instant `stremio-web` assigns it to a `<video>`,
/// suppresses the web element (no double playback), and posts it to Swift.
/// A stream captured from stremio-web, with the metadata the native player needs.
struct CapturedStream {
    let url: URL
    let title: String
    let resumeSeconds: Double   // saved playback position to resume from (0 = start)
    let hasNext: Bool           // a next episode exists (show the Next button)
}

struct StremioWebView: UIViewRepresentable {
    let onPlay: (CapturedStream) -> Void
    let onWebView: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPlay: onPlay) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default() // persist login + library

        let controller = config.userContentController
        controller.add(WeakMessageHandler(context.coordinator), name: Coordinator.channel)
        controller.addUserScript(WKUserScript(source: Self.captureScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-stremiox-debug") {
            controller.addUserScript(WKUserScript(source: "window.__stremioxDebug = true;",
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let i = args.firstIndex(of: "-stremiox-playurl"), i + 1 < args.count {
            controller.addUserScript(WKUserScript(source: Self.selfTestScript(args[i + 1]),
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else if args.contains("-stremiox-selftest") {
            controller.addUserScript(WKUserScript(source: Self.selfTestScript("https://vjs.zencdn.net/v/oceans.mp4"),
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else if args.contains("-stremiox-resume") {
            controller.addUserScript(WKUserScript(source: Self.autoResumeScript,
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if args.contains("-stremiox-settings") {   // dev: open settings + report the server status text
            let js = """
            setTimeout(function(){ location.hash = '#/settings'; }, 9000);
            setTimeout(function(){
              var t = document.body.innerText || '';
              var m = t.match(/127\\.0\\.0\\.1:11470[\\s\\S]{0,60}?(Online|Offline|Error|Loading)/i)
                   || t.match(/(Online|Offline|Error|Loading)[\\s\\S]{0,60}?127\\.0\\.0\\.1:11470/i);
              try { window.webkit.messageHandlers.stremioxPlayer.postMessage({ log: '[serverstatus] ' + (m ? m[1] : 'not-found') }); } catch(e){}
            }, 13000);
            """
            controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.customUserAgent = "StremioX/0.1 (iOS) Mobile"
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        context.coordinator.webView = webView
        // Load the UI from the embedded loopback proxy so the page + its workers can reach the
        // streaming server (no mixed content). Falls back to the remote site if the proxy is off.
        Self.loadUIWhenReady(into: webView)
        // Defer to the next runloop: mutating ContentView's @State synchronously here (during
        // the view-update pass) is silently dropped, leaving its webView nil, which made every
        // native→JS call (progress, seek, exit, next) a no-op.
        DispatchQueue.main.async { onWebView(webView) }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Poll the embedded stremio-web proxy (http://127.0.0.1:11471) and load the UI from it once
    /// the node process has it up. Loopback is a secure context on the http scheme, so the page
    /// and its workers reach the streaming server (:11470) without a mixed-content block, which is
    /// what lets the web UI see the server as online. Falls back to the remote site if the proxy
    /// never comes up (e.g. -stremiox-no-server) so the app still works.
    private static func loadUIWhenReady(into webView: WKWebView, attempt: Int = 0) {
        let proxy = URL(string: "http://127.0.0.1:11471/")!
        var probe = URLRequest(url: proxy)
        probe.timeoutInterval = 2
        probe.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: probe) { _, resp, _ in
            DispatchQueue.main.async {
                if resp is HTTPURLResponse {
                    webView.load(URLRequest(url: proxy))
                } else if attempt < 40 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        loadUIWhenReady(into: webView, attempt: attempt + 1)
                    }
                } else {
                    webView.load(URLRequest(url: URL(string: "https://web.stremio.com")!))
                }
            }
        }.resume()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let channel = "stremioxPlayer"
        private let onPlay: (CapturedStream) -> Void
        weak var webView: WKWebView?
        private let log = Logger(subsystem: "com.stremiox.app", category: "bridge")

        init(onPlay: @escaping (CapturedStream) -> Void) { self.onPlay = onPlay }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.channel, let body = message.body as? [String: Any] else { return }
            if let dbg = body["log"] as? String { log.info("JS: \(dbg, privacy: .public)"); return }
            if let torrent = body["torrent"] as? [String: Any], let infoHash = torrent["infoHash"] as? String {
                handleTorrent(infoHash: infoHash, fileIdx: torrent["fileIdx"] as? Int,
                              sources: torrent["sources"] as? [String] ?? [])
                return
            }
            guard let string = body["url"] as? String,
                  let url = URL(string: string) else { return }
            let title = (body["title"] as? String) ?? ""
            let resumeMs = (body["resumeMs"] as? Double) ?? 0
            let hasNext = (body["hasNext"] as? Bool) ?? false
            log.info("captured stream → \(url.absoluteString, privacy: .public) resume=\(resumeMs)ms next=\(hasNext)")
            onPlay(CapturedStream(url: url, title: title, resumeSeconds: max(0, resumeMs / 1000), hasNext: hasNext))
        }

        /// Create a torrent on the embedded streaming server, then play its file in libmpv.
        /// libmpv reaches http://127.0.0.1:11470 directly (not a web context, no mixed-content,
        /// which is why this can't be done from the WKWebView's JS).
        private func handleTorrent(infoHash: String, fileIdx: Int?, sources: [String]) {
            let ih = infoHash.lowercased()
            let base = "http://127.0.0.1:11470"
            var srcs = sources
            srcs.append("dht:\(ih)")
            if let createURL = URL(string: "\(base)/\(ih)/create"),
               let httpBody = try? JSONSerialization.data(withJSONObject: [
                   "torrent": ["infoHash": ih],
                   "peerSearch": ["sources": srcs, "min": 40, "max": 150],
               ]) {
                var req = URLRequest(url: createURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = httpBody
                URLSession.shared.dataTask(with: req).resume()   // engine creates asynchronously
            }
            let idx = fileIdx ?? 0
            guard let streamURL = URL(string: "\(base)/\(ih)/\(idx)") else { return }
            log.info("torrent → \(streamURL.absoluteString, privacy: .public)")
            onPlay(CapturedStream(url: streamURL, title: "", resumeSeconds: 0, hasNext: false))
        }

        /// Allow the same stream URL to be captured again after the player closes.
        func resetCapture() {
            webView?.evaluateJavaScript("window.__stremioxReset && window.__stremioxReset()", completionHandler: nil)
        }
    }

    // MARK: - Injected JavaScript

    private static let captureScript = #"""
    (() => {
      if (window.__stremioxHook) return;
      window.__stremioxHook = true;
      const seen = new Set();

      // The UI is served from the http://127.0.0.1:11471 loopback proxy (a secure context on the
      // http scheme), so the page and its workers reach the streaming server at :11470 directly,       // no mixed-content block, no JS request bridge needed.

      // Diagnostics: only emits when -stremiox-debug set window.__stremioxDebug. Never logs full
      // URLs (debrid keys); callers truncate. Routed to native os_log via the bridge.
      const dbg = (m) => {
        if (!window.__stremioxDebug) return;
        try { window.webkit.messageHandlers.stremioxPlayer.postMessage({ log: String(m) }); } catch (e) {}
      };

      // Debug probe: can the HTTPS web context reach the embedded http://127.0.0.1:11470 server?
      // dbg() no-ops unless -stremiox-debug; schedule unconditionally so the flag (set by a later
      // userscript) is read at fire time, not at injection time.
      setTimeout(function () {
        fetch('http://127.0.0.1:11470/settings')
          .then(function (r) { dbg('SERVER PROBE: reachable status=' + r.status); })
          .catch(function (e) { dbg('SERVER PROBE: blocked/failed ' + e); });
      }, 7000);

      const suppressOne = (v) => {
        if (!v) return;
        try { v.pause(); } catch (e) {}
        try { v.removeAttribute('src'); } catch (e) {}
        try { v.querySelectorAll('source').forEach(s => s.removeAttribute('src')); } catch (e) {}
        try { v.load(); } catch (e) {}
      };
      const suppress = (el) => {
        if (!el) { document.querySelectorAll('video').forEach(suppressOne); return; }  // decode path: all
        suppressOne(el instanceof HTMLVideoElement ? el : (el.closest ? el.closest('video') : null));
      };

      const send = (raw, el) => {
        let url;
        try { url = new URL(raw, location.href).href; } catch (e) { return; }
        if (!/^https?:/i.test(url)) return;   // skip blob:/data:/mediasource
        if (seen.has(url)) return;
        seen.add(url);
        suppress(el);
        // Title, resume position (ms), and next-episode availability come from the loaded
        // player model. stremio-web never sets document.title per content (it stays the
        // generic tagline), so we read metaItem.content.name instead, empty if unavailable.
        var title = '', resumeMs = 0, hasNext = false;
        try {
          var t = window.services && window.services.core && window.services.core.transport;
          var ps = t && t.getState && t.getState('player');
          if (ps) {
            var off = ps.libraryItem && ps.libraryItem.state && ps.libraryItem.state.timeOffset;
            if (typeof off === 'number' && isFinite(off) && off > 0) resumeMs = off;
            hasNext = !!ps.nextVideo;
            // metaItem.content is a Loadable: the meta directly, or wrapped as { content: meta }.
            var c = ps.metaItem && ps.metaItem.content;
            var meta = c && (typeof c.name === 'string' ? c
                       : (c.content && typeof c.content.name === 'string' ? c.content : null));
            if (meta && meta.name) {
              title = String(meta.name);
              var path = ps.selected && ps.selected.streamRequest && ps.selected.streamRequest.path;
              if (path && typeof path.id === 'string') {
                var sm = path.id.match(/:(\d+):(\d+)$/);   // imdbId:season:episode for series
                if (sm) title += ' · S' + sm[1] + 'E' + sm[2];
              }
            }
          }
        } catch (e) {}
        try { window.webkit.messageHandlers.stremioxPlayer.postMessage({ url, title, resumeMs, hasNext }); } catch (e) {}
      };

      const mediaSrc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (mediaSrc && mediaSrc.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          get: mediaSrc.get,
          set(value) { send(value, this); }   // suppress: do not forward to the web element
        });
      }

      const setAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(name, value) {
        if (String(name).toLowerCase() === 'src' &&
            (this instanceof HTMLVideoElement || this instanceof HTMLSourceElement)) {
          send(value, this);
          return;                              // suppress
        }
        return setAttr.call(this, name, value);
      };

      new MutationObserver(list => list.forEach(m => {
        if (m.type === 'attributes' && m.attributeName === 'src' &&
            (m.target instanceof HTMLVideoElement || m.target instanceof HTMLSourceElement)) {
          send(m.target.getAttribute('src'), m.target);
        }
        m.addedNodes && m.addedNodes.forEach(n => {
          if (n instanceof HTMLVideoElement && (n.currentSrc || n.src)) send(n.currentSrc || n.src, n);
        });
      })).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['src']
      });

      window.__stremioxReset = () => seen.clear();

      // stremio-core transport. The production bundle keeps it at services.core.transport
      // (the dev-build `window.core` alias does NOT exist here). Action shapes below are
      // byte-for-byte what stremio-web's own player dispatches (verified against main.js).
      const transport = () => {
        try { return window.services && window.services.core && window.services.core.transport; }
        catch (e) { return null; }
      };
      const playerDispatch = (inner) => {
        const t = transport();
        if (!t || typeof t.dispatch !== 'function') return false;
        try { t.dispatch({ action: 'Player', args: inner }, 'player'); return true; } catch (e) { return false; }
      };

      // Forward progress (advances time_offset); the player route is mounted, we suppress
      // only the <video>, not the React route, so the core has the item Loaded.
      // stremio-web's `time`/`duration` are in MILLISECONDS (verified: it does currentTime=time/1e3
      // on resume and time=1e3*currentTime on report). libmpv gives seconds, so ×1000 here.
      const ms = (sec) => Math.max(0, Math.round(sec * 1000));
      window.__stremioxProgress = function (timeSec, durationSec) {
        if (!(durationSec > 0) || timeSec < 0) return;
        playerDispatch({ action: 'TimeChanged', args: { time: ms(timeSec), duration: ms(durationSec), device: 'libmpv' } });
      };
      // Exact position (any direction), mirrors the web player's user-seek dispatch.
      window.__stremioxSeek = function (timeSec, durationSec) {
        if (!(durationSec > 0) || timeSec < 0) return;
        playerDispatch({ action: 'Seek', args: { time: ms(timeSec), duration: ms(durationSec), device: 'libmpv' } });
      };
      // Mark fully watched.
      window.__stremioxEnded = function () { playerDispatch({ action: 'Ended' }); };

      // Advance to the next episode (mirrors the web player's next handler: navigate via
      // nextVideo.deepLinks). Prefers a direct player link; falls back to the episode page.
      window.__stremioxNext = function () {
        try {
          const t = transport();
          const ps = t && t.getState && t.getState('player');
          const nv = ps && ps.nextVideo;
          if (!nv || !nv.deepLinks) return false;
          const dl = nv.deepLinks;
          const href = (typeof dl.player === 'string' && dl.player) ||
                       (typeof dl.metaDetailsStreams === 'string' && dl.metaDetailsStreams) ||
                       (typeof dl.metaDetailsVideos === 'string' && dl.metaDetailsVideos) || null;
          if (!href) return false;
          seen.clear();                 // let the next episode's stream URL be captured
          window.location = href;
          return true;
        } catch (e) { return false; }
      };

      // Leave the player route cleanly (history.back = what the web back button does;
      // unmounts <Player> -> core dispatches Unload -> flushes progress to library/API).
      window.__stremioxExit = function () {
        try {
          if (!/player/i.test(location.hash || '')) return;
          // 1) Click stremio-web's own back button (what the user taps to escape the splash).
          var sels = ['[class*="back-button"]', '[class*="backButton"]', '[title="Back"]',
                      '[aria-label="Back"]', 'a[href="#/"]', '[class*="control-bar"] [class*="button"]'];
          for (var i = 0; i < sels.length; i++) {
            var el = document.querySelector(sels[i]);
            if (el) { try { el.click(); } catch (e) {} break; }
          }
          // 2) history.back(), then a deterministic fallback if still stuck on the player route.
          try { window.history.back(); } catch (e) {}
          setTimeout(function () {
            if (/player/i.test(location.hash)) location.hash = '#/';
          }, 250);
        } catch (e) {}
      };

      // PRIMARY playback trigger: decode the stream URL straight from the player hash and play
      // it in libmpv immediately, no waiting for stremio-web to set the <video> src (it only does
      // that once the streaming server cooperates; that wait is the "stuck on splash" bug).
      let lastPlayerSeg = null;
      const checkPlayerRoute = async () => {
        const m = (location.hash || '').match(/^#\/player\/([^/]+)/);
        if (!m) { if (lastPlayerSeg) seen.clear(); lastPlayerSeg = null; return; }  // left player: allow replay
        if (m[1] === lastPlayerSeg) return;                 // already handled this stream
        lastPlayerSeg = m[1];
        dbg('player route detected, seg len=' + m[1].length);
        const t = transport();
        if (!t || !t.decodeStream) { dbg('transport/decodeStream NOT ready'); lastPlayerSeg = null; return; }   // retry once transport is ready
        try {
          const stream = await t.decodeStream(decodeURIComponent(m[1]));
          dbg('decoded: ' + (stream ? ('keys=' + Object.keys(stream).join(',')
              + ' url=' + (stream.url ? String(stream.url).slice(0, 12) : 'NONE')
              + ' infoHash=' + (stream.infoHash ? 'yes' : 'no')) : 'NULL'));
          if (stream && stream.behaviorHints) {
            var bh = stream.behaviorHints, ph = bh.proxyHeaders && bh.proxyHeaders.request;
            dbg('behaviorHints: keys=' + Object.keys(bh).join(',')
                + ' notWebReady=' + (bh.notWebReady ? 'yes' : 'no')
                + ' proxyReqHdrs=' + (ph ? Object.keys(ph).join('|') : 'none'));
          }
          const url = stream && stream.url;
          if (url && /^https?:/i.test(url)) {
            dbg('-> sending http url to libmpv');
            // Wait briefly for the library item to load so send() reads the saved resume
            // position (timeOffset). It's null/0 for a beat after the route mounts.
            for (let i = 0; i < 15; i++) {
              const li = (t.getState('player') || {}).libraryItem;
              if (li && li.state) break;
              await new Promise(r => setTimeout(r, 100));
            }
            send(url, null);                                // suppress web videos + play in libmpv
          } else if (stream && stream.infoHash) {
            dbg('-> torrent path (infoHash), needs streaming server');
            // Torrent: the WKWebView can't reach the http server (mixed-content), so hand the
            // infoHash to native, which creates the torrent on the embedded server and plays
            // the file URL in libmpv (libmpv isn't a web context, no mixed-content).
            document.querySelectorAll('video').forEach(function (v) {
              try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {}
            });
            const payload = { infoHash: String(stream.infoHash),
                              fileIdx: (typeof stream.fileIdx === 'number') ? stream.fileIdx : null,
                              sources: stream.sources || stream.announce || [] };
            try { window.webkit.messageHandlers.stremioxPlayer.postMessage({ torrent: payload }); } catch (e) {}
          } else {
            dbg('-> NOT PLAYABLE: no http url and no infoHash');
          }
        } catch (e) { dbg('decodeStream THREW: ' + e); lastPlayerSeg = null; }
      };
      window.addEventListener('hashchange', checkPlayerRoute);
      setInterval(checkPlayerRoute, 800);
    })();
    """#

    /// Dev-only (`-stremiox-selftest` or `-stremiox-playurl <url>`): simulates Stremio assigning a
    /// stream URL to a <video> so the full capture → native-player path can be verified in the sim.
    private static func selfTestScript(_ url: String) -> String {
        let jsURL = (try? JSONSerialization.data(withJSONObject: [url]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        setTimeout(() => {
          const v = document.createElement('video');
          v.src = \(jsURL);
        }, 3500);
        """
    }

    /// Dev-only (`-stremiox-resume`): deterministically drive the real flow without screen
    /// clicks, board → metadetails → first stream → player, so the decode-path runs against a
    /// real stream object. Logs each hop via the bridge (with `-stremiox-debug`).
    private static let autoResumeScript = #"""
    (function () {
      var post = function (m) { try { window.webkit.messageHandlers.stremioxPlayer.postMessage({ log: '[resume] ' + m }); } catch (e) {} };
      var transport = function () { try { return window.services.core.transport; } catch (e) { return null; } };
      var navigated = false, clickedStream = false, busy = false, tries = 0;

      // Decode every #/player/ link on the page and return the first whose stream has a real
      // http url, this skips the YouTube trailer (decodes to {ytId} with no url) and only picks
      // an actual addon/debrid stream once the stream addon has populated the list.
      async function findRealStreamLink() {
        var t = transport(); if (!t || !t.decodeStream) return null;
        var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="#/player/"]'));
        for (var i = 0; i < links.length; i++) {
          var mm = (links[i].getAttribute('href') || '').match(/#\/player\/([^/]+)/);
          if (!mm) continue;
          try {
            var s = await t.decodeStream(decodeURIComponent(mm[1]));
            if (s && typeof s.url === 'string' && /^https?:/i.test(s.url)) return links[i];
          } catch (e) {}
        }
        return null;
      }

      async function step() {
        if (busy) return; busy = true; tries++;
        try {
          var hash = location.hash || '';
          // 1) Streams page (movie/series detail): click the first real (non-trailer) stream.
          if (/#\/(metadetails|detail)\//.test(hash)) {
            if (clickedStream) return;
            var link = await findRealStreamLink();
            if (link) { clickedStream = true; post('click REAL stream'); link.click(); }
            else post('detail: waiting for real stream (addon)…');
            return;
          }
          // 2) Player route: the decode-path takes over from here.
          if (/#\/player\//.test(hash)) { post('on player route'); return; }
          // 3) Board / discover / anywhere else: open the first MOVIE detail page (movies show
          //    streams directly, no episode picker). Require the detail/metadetails *route* so
          //    we don't match a #/discover/.../movie/... catalog link.
          if (!navigated) {
            var a = document.querySelector('a[href*="#/detail/movie/"]')
                 || document.querySelector('a[href*="#/metadetails/movie/"]')
                 || document.querySelector('a[href*="#/detail/"]')
                 || document.querySelector('a[href*="#/metadetails/"]');
            if (a) { navigated = true; post('open detail -> ' + (a.getAttribute('href').match(/#\/[a-z]+\/[a-z]+/) || ['?'])[0]); a.click(); }
            else post('no detail anchor (anchors=' + document.querySelectorAll('a[href^="#/"]').length + ')');
          }
        } finally { busy = false; }
      }
      var iv = setInterval(function () {
        if (tries > 45 || /#\/player\//.test(location.hash)) { clearInterval(iv); }
        step();
      }, 800);
    })();
    """#
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
