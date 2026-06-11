import Foundation
import NodeMobile

/// Runs Stremio's streaming server (server.js) inside the app via nodejs-mobile,
/// listening on http://127.0.0.1:11470. This enables torrent / uncached streams
/// (debrid/direct streams play without it). node_start() blocks, so it runs on a
/// dedicated thread with a large stack (Node needs one).
enum NodeServer {
    private(set) static var started = false
    /// Set when node_start returns: node exited and CANNOT be restarted in-process (a
    /// nodejs-mobile limitation); only an app relaunch brings the server back.
    private(set) static var exitCode: Int32?

    /// One-line state for the Settings diagnostics.
    static var statusDescription: String {
        if PlaybackSettings.torrentsDisabled { return "Disabled by Direct Links Only" }
        if !started { return "Not started (server.js missing from the bundle)" }
        if let code = exitCode { return "Server exited with code \(code). Relaunch the app to restart it." }
        return "Server process running"
    }

    /// The last lines of the server's own log (console output + crashes are teed to a file), so a
    /// dead or misbehaving server can explain itself right in Settings.
    static func logTail(_ lines: Int = 4) -> [String] {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let path = (caches as NSString).appendingPathComponent("stremio-server.log")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map(String.init)
    }

    static func startIfNeeded() {
        guard !started else { return }
        guard let serverJs = Bundle.main.path(forResource: "server", ofType: "js") else {
            NSLog("StremioX: server.js not found in bundle, streaming server disabled")
            return
        }
        started = true
        let thread = Thread { runNode(serverJs) }
        thread.name = "stremio-node-server"
        thread.stackSize = 8 * 1024 * 1024   // Node requires a large stack
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static func runNode(_ scriptPath: String) {
        // The server writes a cache (torrent pieces, settings), point it at a writable
        // sandbox dir. It reads HOME for its app-data path.
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let serverData = (caches as NSString).appendingPathComponent("stremio-server")
        try? FileManager.default.createDirectory(atPath: serverData, withIntermediateDirectories: true)
        setenv("HOME", caches, 1)
        setenv("APP_PATH", serverData, 1)
        setenv("NO_CORS", "1", 1)
        // CRITICAL: disable casting/SSDP. The server's Chromecast/DLNA discovery is
        // UDP multicast, which does not work in the embedded runtime on tvOS, so it
        // errors in an unthrottled loop ("SSDP error: [object Object]") that saturates
        // the node event loop and pegs the CPU. On a device left running a while this
        // reached ~3 million errors, which starved torrent peer discovery (0 peers)
        // and made the whole app's remote sluggish (only system play/pause survived).
        // server.js gates the entire casting subsystem behind this flag, which the
        // official mobile builds set via IOS_APP / TV_ENV; we never did, and that was
        // the bug behind "torrents stopped loading" and "the remote freezes in torrents".
        setenv("CASTING_DISABLED", "1", 1)
        // Give libuv more worker threads. With UDP dead, peer-search leans on HTTP/HTTPS
        // tracker announces; their DNS lookups (getaddrinfo) and the engine's disk/crypto
        // all share the libuv threadpool (default 4). Many dead trackers resolving slowly
        // can saturate it and stall the engine. 16 threads relieves that contention. Cheap
        // and harmless; the heartbeat in the preload tells us if the loop still freezes.
        setenv("UV_THREADPOOL_SIZE", "16", 1)
        // Memory: the server defaults its torrent cache to 2 GB, which is a lot for the
        // Apple TV's per-app memory budget. We do NOT disable caching (that thins the
        // torrent buffer); instead the app caps it to a TV-safe size via a /settings
        // POST once the server is up (StremioServer.applyServerConfig). The player's own
        // read-ahead buffer and the binge preload are separate from this and unaffected.
        FileManager.default.changeCurrentDirectoryPath(caches)

        // node's stdout/stderr aren't surfaced by nodejs-mobile, so tee console + uncaught
        // errors to a log file we can read (essential for debugging the torrent engine).
        let logPath = (caches as NSString).appendingPathComponent("stremio-server.log")
        let preloadPath = (caches as NSString).appendingPathComponent("stremiox-preload.js")
        let preload = """
        const fs=require('fs'),L=\(jsString(logPath));
        const w=(t,a)=>{try{fs.appendFileSync(L,t+' '+Array.prototype.map.call(a,String).join(' ')+'\\n')}catch(e){}};
        console.log=function(){w('[log]',arguments)};console.error=function(){w('[err]',arguments)};
        console.warn=function(){w('[warn]',arguments)};
        process.on('uncaughtException',function(e){w('[uncaught]',[e&&e.stack||e])});
        process.on('unhandledRejection',function(e){w('[rej]',[e&&e.stack||e])});
        w('[boot]',['preload active']);

        // Tracker-announce tap: UDP/DHT are dead in this sandbox, so peers can ONLY
        // come from HTTP/HTTPS trackers. Wrap the (shared, core) http/https.request to
        // log every "/announce" and its result, so a device run shows definitively
        // whether the trackers are reached, what they return, and whether peers come
        // back -- instead of us guessing why connectionTries stays 0. http.get calls
        // http.request internally, so wrapping request covers both.
        (function(){
          ['http','https'].forEach(function(modName){
            var mod; try { mod = require(modName); } catch(e){ return; }
            var orig = mod.request;
            mod.request = function(){
              var req = orig.apply(this, arguments);
              try {
                var a0 = arguments[0];
                var u = (typeof a0 === 'string') ? a0
                      : (a0 && (a0.href || (modName + '://' + (a0.hostname || a0.host || '') + (a0.path || ''))));
                if (u && u.indexOf('/announce') !== -1) {
                  w('[trk]', ['-> ' + u]);
                  req.on('response', function(res){ var n=0; res.on('data', function(d){ n += d.length; }); res.on('end', function(){ w('[trk]', ['<- HTTP ' + res.statusCode + ' ' + n + 'B ' + u]); }); });
                  req.on('error', function(e){ w('[trk]', ['ERR ' + u + ': ' + (e && e.message || e)]); });
                }
              } catch(e){}
              return req;
            };
          });
        })();

        // Event-loop heartbeat: the decisive instrument for the "server froze / went
        // offline" symptom. Every second, log the loop lag (how late this tick fired vs
        // the 1s schedule) plus RSS/heap. If the loop FREEZES, these [hb] lines stop dead
        // and the gap + last lag pinpoint the moment; if it's MEMORY, rss climbs before
        // the process dies. Either way the next device run names the cause instead of us
        // guessing. ~60 lines/min, fine for a short repro.
        (function(){
          var last = Date.now();
          setInterval(function(){
            try {
              var now = Date.now(), lag = now - last - 1000; last = now;
              var m = process.memoryUsage();
              w('[hb]', ['lag=' + lag + 'ms rss=' + Math.round(m.rss/1048576) + 'MB heap=' + Math.round(m.heapUsed/1048576) + 'MB']);
            } catch(e){}
          }, 1000);
        })();

        // Boot probes: which outbound layers work in this node build? (UDP probe
        // result on device: ping "sent", no pong ever. These narrow it further.)
        (function(){
          function probeHttp(mod, name, url){ try {
            var req = mod.get(url, function(res){ w('[probe]', [name + ' OK: HTTP ' + res.statusCode]); res.resume(); });
            req.on('error', function(e){ w('[probe]', [name + ' ERROR: ' + e]); });
            req.setTimeout(8000, function(){ w('[probe]', [name + ' TIMEOUT']); try{req.destroy()}catch(_){} });
          } catch(e){ w('[probe]', [name + ' THREW: ' + e]); } }
          probeHttp(require('https'), 'outbound HTTPS (strem.io)', 'https://www.strem.io/');
          probeHttp(require('http'), 'outbound HTTP (opentrackr:1337)', 'http://tracker.opentrackr.org:1337/announce');
          try {
            var net = require('net');
            var c = net.connect({ host: 'one.one.one.one', port: 80 }, function(){ w('[probe]', ['outbound TCP OK (one.one.one.one:80)']); c.destroy(); });
            c.setTimeout(8000, function(){ w('[probe]', ['outbound TCP TIMEOUT']); c.destroy(); });
            c.on('error', function(e){ w('[probe]', ['outbound TCP ERROR: ' + e]); });
          } catch(e){ w('[probe]', ['TCP THREW: ' + e]); }
        })();

        // Boot probe: is UDP (dgram) functional in this node build? BitTorrent peer
        // discovery is UDP-first (DHT, udp trackers); a broken dgram on the device
        // slice would explain torrents finding zero peers while HTTP works fine.
        (function(){
          try {
            var dgram = require('dgram');
            var s = dgram.createSocket('udp4');
            var ping = Buffer.from('d1:ad2:id20:abcdefghij0123456789e1:q4:ping1:t2:aa1:y1:qe');
            var done = false;
            s.on('message', function(m, r){ done = true; w('[probe]', ['UDP OK: DHT pong from ' + r.address + ', ' + m.length + ' bytes']); try{s.close()}catch(_){ } });
            s.on('error', function(e){ w('[probe]', ['UDP socket error: ' + e]); });
            s.send(ping, 0, ping.length, 6881, 'router.bittorrent.com', function(e){
              if (e) w('[probe]', ['UDP send error: ' + e]); else w('[probe]', ['UDP DHT ping sent']);
            });
            setTimeout(function(){ if (!done) w('[probe]', ['UDP probe: no pong in 10s (UDP likely broken or blocked)']); try{s.close()}catch(_){ } }, 10000);
          } catch (e) { w('[probe]', ['UDP unavailable: ' + e]); }
        })();

        // (The wake watchdog that used to live here has been removed.) It self-pinged
        // /settings and, on two failures, force-closed and re-listened the HTTP servers
        // including port 11470 -- the torrent engine's own server. That close-mid-torrent
        // showed up as "this source didn't load", and because a re-listen briefly made
        // the next self-ping fail, it looped forever (the device log was nothing but
        // "[watchdog] server unreachable, rebinding"). Its whole reason for existing --
        // "the server is dead after the Apple TV sleeps" -- was really the casting/SSDP
        // error flood saturating the event loop, which is now fixed at the source with
        // CASTING_DISABLED above. The server is stable on its own; if a real
        // post-suspension recovery is ever needed it must NOT force-close 11470 during
        // playback. The Settings > Restart button covers the manual case.

        // Reverse-proxy stremio-web on http://127.0.0.1:11471 so the WKWebView can load the UI
        // from a loopback origin. Loopback is a secure context (Service Workers / WASM / crypto
        // all work) yet uses the http scheme, so the page AND its workers can reach the streaming
        // server at http://127.0.0.1:11470 with no mixed-content block (that's the whole reason the
        // web UI showed the server as "Error" when loaded from https web.stremio.com). We strip
        // CSP/HSTS/frame headers so the proxied page renders, and rewrite redirects to stay local.
        (function () {
          try {
            var http = require('http'), https = require('https'), UP = 'web.stremio.com';
            http.createServer(function (req, res) {
              var opts = { host: UP, path: req.url, method: req.method,
                headers: Object.assign({}, req.headers, { host: UP }) };
              var preq = https.request(opts, function (pres) {
                var h = Object.assign({}, pres.headers);
                delete h['content-security-policy']; delete h['content-security-policy-report-only'];
                delete h['strict-transport-security']; delete h['x-frame-options'];
                if (h.location) h.location = String(h.location).split('https://' + UP).join('').split('http://' + UP).join('');
                res.writeHead(pres.statusCode, h);
                pres.pipe(res);
              });
              preq.on('error', function (e) { try { res.writeHead(502); res.end(String(e)); } catch (_) {} });
              req.pipe(preq);
            }).listen(11471, '127.0.0.1', function () { w('[proxy]', ['stremio-web on 11471']); });
          } catch (e) { w('[proxy-err]', [String(e)]); }
        })();
        """
        try? preload.write(toFile: preloadPath, atomically: true, encoding: .utf8)
        // Keep the tail of the previous boot's log instead of wiping it, so a crash that
        // takes the whole app (and this server) down leaves its last lines readable after
        // relaunch. Capped so it can't grow without bound.
        let prior = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let keptTail = prior.count > 48_000 ? String(prior.suffix(48_000)) : prior
        try? (keptTail + "\n===== BOOT =====\n").write(toFile: logPath, atomically: true, encoding: .utf8)

        NSLog("StremioX: starting node streaming server (HOME=\(caches), log=\(logPath))")
        var argv: [UnsafeMutablePointer<CChar>?] =
            [strdup("node"), strdup("-r"), strdup(preloadPath), strdup(scriptPath), nil]
        let rc = node_start(4, &argv)
        exitCode = rc
        NSLog("StremioX: node server exited rc=\(rc)")
    }

    /// JSON-encode a string for safe embedding in the preload JS literal.
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // unwrap the [ ... ] → the quoted string
    }
}
