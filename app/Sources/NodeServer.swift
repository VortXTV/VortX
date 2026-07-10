import Foundation
import Darwin   // sockets (waitForPortFree) + rlimit (RLIMIT_NOFILE raise) before node boots
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

    // MARK: - Discovered-port latch
    //
    // server.js targets 11470 but SILENTLY falls back to 11471-11474 on EADDRINUSE (a fast-relaunch
    // race), and Swift used to hardcode 11470 -- so a drifted port stranded the whole session (badge
    // Offline, every torrent request refused). The preload's console sniffer (A2) writes the ACTUAL
    // bound port to a small file; this latch caches it so StremioServer.embedded follows it. The
    // Settings probe scan (StremioServer.isOnline) also latches a live port it finds.
    private static let portLock = NSLock()
    /// THIS boot's bound port, cached once the preload has written the port file. AUTHORITATIVE: it always
    /// wins in discoveredPort, so once this boot's server binds, its real port beats any stale scan latch.
    private static var fileLatchedPort: Int?
    /// A port found by the Settings reachability scan (StremioServer.isOnline). Only a FALLBACK, never
    /// allowed to shadow this boot's own preload file: a scan can transiently reach a DYING previous
    /// instance still answering on a drifted port. Cleared on each boot in startIfNeeded().
    private static var scanLatchedPort: Int?
    /// The port the embedded server ACTUALLY bound, or nil if not yet known. Prefers THIS boot's preload
    /// file (via the fileLatchedPort cache, else a fresh read) over a scan latch, so a recovery boot that
    /// binds 11470 is never shadowed by a stale 11471 latched from a previous, dying session. Validated to
    /// the 11470-11474 fallback range.
    static var discoveredPort: Int? {
        portLock.lock(); defer { portLock.unlock() }
        if let p = fileLatchedPort { return p }
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let path = (caches as NSString).appendingPathComponent("stremio-server.port")
        if let s = try? String(contentsOfFile: path, encoding: .utf8),
           let p = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), (11470...11474).contains(p) {
            fileLatchedPort = p; return p
        }
        return scanLatchedPort
    }
    /// Latch a port discovered by the Settings reachability scan (bounded to the fallback range). Only a
    /// fallback: this boot's preload file (fileLatchedPort) always wins in discoveredPort.
    static func latch(port: Int) {
        guard (11470...11474).contains(port) else { return }
        portLock.lock(); scanLatchedPort = port; portLock.unlock()
    }

    /// One-line state for the Settings diagnostics.
    static var statusDescription: String {
        if PlaybackSettings.torrentsDisabled { return "Disabled by Direct Links Only" }
        if !started { return "Not started (server.js missing from the bundle)" }
        if let code = exitCode { return "Server exited with code \(code). Relaunch the app to restart it." }
        // The preload heartbeat writes the log every ~1s; a much older last-write while the process is
        // still alive means the node event loop has stalled (froze rather than exited). Surface that so
        // Settings can distinguish a wedged loop from a healthy one.
        if let age = lastLogTickAge(), age > 10 {
            return "Server process running, but its event loop last ticked \(Int(age))s ago. Restart the app."
        }
        return "Server process running"
    }

    /// Age in seconds of the server log's last write. The preload heartbeat writes every ~1s, so a value
    /// well past that (while the process is alive) means the event loop has frozen. Best-effort, nil when
    /// the log is absent/unreadable, in which case the caller falls back to the plain running state.
    private static func lastLogTickAge() -> TimeInterval? {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let path = (caches as NSString).appendingPathComponent("stremio-server.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(mtime)
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
        // Fresh-boot the discovered-port state synchronously, BEFORE the node thread starts: clear last
        // session's port file AND both in-memory latches, so a stale file or a scan latch from a dying
        // previous instance can never shadow the port THIS boot is about to bind. runNode also clears the
        // file (belt and braces); doing it here too closes the window before any foreground/isOnline probe.
        let portCaches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        try? FileManager.default.removeItem(atPath: (portCaches as NSString).appendingPathComponent("stremio-server.port"))
        portLock.lock(); fileLatchedPort = nil; scanLatchedPort = nil; portLock.unlock()
        let thread = Thread { runNode(serverJs) }
        thread.name = "stremio-node-server"
        thread.stackSize = 8 * 1024 * 1024   // Node requires a large stack
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static func runNode(_ scriptPath: String) {
        // Resolve the writable cache dir + log path up front and stamp a fresh BOOT marker into the log
        // BEFORE the (up-to-10s) port wait and node boot. This keeps the log's mtime current from the very
        // start of the boot, so statusDescription's stale-loop check (log mtime age) cannot false-alarm off
        // the PREVIOUS session's last write during the pre-boot window. We keep the tail of the previous
        // boot's log instead of wiping it, so a crash that took the whole app down leaves its last lines
        // readable after relaunch. Capped so it can't grow without bound.
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let logPath = (caches as NSString).appendingPathComponent("stremio-server.log")
        let prior = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let keptTail = prior.count > 48_000 ? String(prior.suffix(48_000)) : prior
        try? (keptTail + "\n===== BOOT =====\n").write(toFile: logPath, atomically: true, encoding: .utf8)

        // Wait for :11470 to become bindable before node boots, so server.js's silent EADDRINUSE
        // fallback (11471-11474, invisible to Swift) never engages on a fast relaunch. This runs on
        // the node thread, so it delays only node boot, never the UI.
        Self.waitForPortFree(11470, timeout: 10)

        // Raise the soft fd limit to the hard cap before node opens its torrent sockets. The iOS/tvOS
        // default is 256; one process runs node (24 peer sockets per engine + announce bursts to
        // 40-150 trackers + piece-cache files) alongside mpv + URLSession. On EMFILE, libuv
        // accept-and-closes incoming connections: mpv gets an INSTANT "error loading failed" and the
        // Settings probe reads Offline while the process is perfectly alive. Standard POSIX, sandbox-legal.
        var lim = rlimit()
        if getrlimit(RLIMIT_NOFILE, &lim) == 0 {
            // min(OPEN_MAX, rlim_max): if rlim_max is "unlimited" (all-ones) the min clamps to OPEN_MAX; if it is
            // finite we take it. Avoids referencing RLIM_INFINITY (a C macro not imported into Swift on this SDK).
            let want = min(rlim_t(OPEN_MAX), lim.rlim_max)
            if lim.rlim_cur < want {
                lim.rlim_cur = want
                if setrlimit(RLIMIT_NOFILE, &lim) == 0 { NSLog("StremioX: RLIMIT_NOFILE raised to \(want)") }
            }
        }

        // The server writes a cache (torrent pieces, settings), point it at a writable
        // sandbox dir (`caches`, resolved above). It reads HOME for its app-data path.
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
        // CRITICAL (regression fix, #56): the in-process nodejs-mobile runtime CANNOT spawn child
        // processes in the iOS/tvOS sandbox, so the server's :12470 HTTPS endpoint and its HLSv2
        // transcoder (which shells out to ffmpeg via child_process.spawn) MUST be disabled — exactly
        // what official Stremio's own mobile build does (server.js force-sets both under IOS_APP).
        // Without them the boot-time hwAccel profiler fires a /hlsv2 probe that spawns ffmpeg, the spawn
        // is denied, and the node runtime dies ~10s after launch (the "server goes Offline" report).
        // A prior commit removed these on the mistaken theory that the death was only the 11471
        // web-proxy's EADDRINUSE — but that proxy is gated to the web-host target and never runs here,
        // so removing them just re-exposed the native apps to the iOS-incompatible HTTPS/HLS/spawn paths.
        // Do NOT set IOS_APP itself: server.js would then call a native apple_bridge binding that isn't
        // linked in this app and would throw. These two discrete flags are the correct substitute.
        setenv("NO_HTTPS_SERVER", "1", 1)
        setenv("HLS_V2_DISABLED", "1", 1)
        #if VORTX_WEB_HOST
        // Only the WKWebView web-host target needs the 11471 reverse-proxy of web.stremio.com (so the
        // webview can load the UI from a loopback origin). The native iOS/tvOS apps have no webview, so
        // the preload skips that idle HTTP server + its per-request https buffers there — more footprint
        // shed on the 2 GB Apple TV HD (issue #56). See the gated block in the preload below.
        setenv("NEEDS_WEB_PROXY", "1", 1)
        #endif
        // Memory: the server defaults its torrent cache to 2 GB, which is a lot for the
        // Apple TV's per-app memory budget. We do NOT disable caching (that thins the
        // torrent buffer); instead the app caps it to a TV-safe size via a /settings
        // POST once the server is up (StremioServer.applyServerConfig). The player's own
        // read-ahead buffer and the binge preload are separate from this and unaffected.
        FileManager.default.changeCurrentDirectoryPath(caches)

        // node's stdout/stderr aren't surfaced by nodejs-mobile, so we tee console + uncaught errors to
        // `logPath` (resolved and BOOT-stamped at the top of this function) via the preload below.
        // The preload writes the ACTUAL bound port here once server.js logs "EngineFS server started
        // at ..."; NodeServer.discoveredPort reads it and StremioServer.embedded follows it. Clear any
        // stale value from a previous boot so a drifted port is never trusted across launches (the file
        // is rewritten the moment this boot's server binds).
        let portPath = (caches as NSString).appendingPathComponent("stremio-server.port")
        try? FileManager.default.removeItem(atPath: portPath)
        let preloadPath = (caches as NSString).appendingPathComponent("stremiox-preload.js")
        let preload = """
        const fs=require('fs'),L=\(jsString(logPath)),PORTF=\(jsString(portPath));
        let LFD=null; try{LFD=fs.openSync(L,'a')}catch(e){}
        const w=(t,a)=>{try{var line=new Date().toISOString().slice(11,19)+' '+t+' '+Array.prototype.map.call(a,String).join(' ')+'\\n';if(LFD!==null){fs.writeSync(LFD,line)}else{fs.appendFileSync(L,line)}}catch(e){}};
        console.log=function(){try{var s=Array.prototype.join.call(arguments,' ');var m=s.match(/EngineFS server started at http:\\/\\/127\\.0\\.0\\.1:(\\d{4,5})/);if(m){try{fs.writeFileSync(PORTF,m[1])}catch(e){}}}catch(e){}w('[log]',arguments)};
        console.error=function(){w('[err]',arguments)};
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
          if (!process.env.NEEDS_WEB_PROXY) return;   // web-host target only; native iOS/tvOS have no WKWebView
          try {
            var http = require('http'), https = require('https'), UP = 'web.stremio.com';
            var proxySrv = http.createServer(function (req, res) {
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
            });
            // CRITICAL: listen() reports EADDRINUSE (a previous instance still holds 11471 after a fast
            // relaunch / force-quit) as an async 'error' EVENT, not a throw, so the try/catch below could
            // never catch it. Without this handler it was an UNCAUGHT exception that crashed the whole node
            // runtime and took the 11470 streaming server down with it: the "server dies within seconds on
            // relaunch" crash (NOT a memory/jetsam issue). Swallow it; the instance already on the port serves.
            proxySrv.on('error', function (e) { w('[proxy-err]', ['11471 listen: ' + (e && e.message || e)]); });
            proxySrv.listen(11471, '127.0.0.1', function () { w('[proxy]', ['stremio-web on 11471']); });
          } catch (e) { w('[proxy-err]', [String(e)]); }
        })();
        """
        try? preload.write(toFile: preloadPath, atomically: true, encoding: .utf8)
        // (The log was already tail-kept + BOOT-stamped at the top of this function, so its mtime is fresh
        // from boot start; nothing to rewrite here.)

        NSLog("StremioX: starting node streaming server (HOME=\(caches), log=\(logPath))")
        var argv: [UnsafeMutablePointer<CChar>?] =
            [strdup("node"), strdup("-r"), strdup(preloadPath), strdup(scriptPath), nil]
        // strdup mallocs each argv entry; node_start returns when the runtime exits, so free
        // them afterward to avoid leaking on every (re)start and on the exit path.
        defer { argv.forEach { if let p = $0 { free(p) } } }
        let rc = node_start(4, &argv)
        exitCode = rc
        NSLog("StremioX: node server exited rc=\(rc)")
    }

    /// tvOS/iOS cannot see or kill a stale previous instance holding 11470 (no lsof/kill in the sandbox,
    /// unlike MacNodeServer.reclaimStalePort). Instead WAIT for the port to become bindable before starting
    /// node, so server.js's silent EADDRINUSE fallback (11471-11474, invisible to Swift) never engages on a
    /// fast relaunch. The stale holder is always a DYING previous process; it frees the port within moments.
    private static func waitForPortFree(_ port: UInt16, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd)
            if rc == 0 { return }   // bindable: previous holder is gone
            NSLog("StremioX: 11470 still held by a dying instance, waiting")
            Thread.sleep(forTimeInterval: 0.25)
        }
        NSLog("StremioX: 11470 not freed within \(timeout)s; node may fall back to 11471+ (latch will follow it)")
    }

    /// JSON-encode a string for safe embedding in the preload JS literal.
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // unwrap the [ ... ] → the quoted string
    }
}
