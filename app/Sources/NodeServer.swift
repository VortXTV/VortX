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

        // Wake watchdog. Long tvOS suspension (overnight sleep) tears the listener
        // sockets down; node survives (exceptions are trapped above) but the HTTP
        // server never re-binds, so the app wakes to a dead server and only a
        // relaunch helped. Capture every server and its listen() args, self-ping
        // the streaming port, and re-bind dead listeners automatically.
        var __servers=[];
        (function(){
          var http=require('http'); var orig=http.createServer;
          http.createServer=function(){
            var s=orig.apply(http,arguments); var ol=s.listen;
            s.listen=function(){ s.__args=Array.prototype.slice.call(arguments).filter(function(a){return typeof a!=='function'}); return ol.apply(s,arguments) };
            __servers.push(s); return s;
          };
        })();
        (function(){
          var http=require('http'); var failures=0;
          setInterval(function(){
            var req=http.get({host:'127.0.0.1',port:11470,path:'/settings',timeout:4000},function(res){failures=0;res.resume()});
            function heal(){
              if(++failures<2) return;
              failures=0; w('[watchdog]',['server unreachable, rebinding '+__servers.length+' listeners']);
              __servers.forEach(function(s){
                try{ var a=s.__args||[]; s.close(function(){ try{ s.listen.apply(s,a); w('[watchdog]',['relistened on '+JSON.stringify(a)]) }catch(e){ w('[watchdog-err]',[String(e)]) } }); }
                catch(e){ w('[watchdog-err]',[String(e)]) }
              });
            }
            req.on('error',heal);
            req.on('timeout',function(){ try{req.destroy()}catch(_){}; heal() });
          },30000);
        })();

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
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

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
