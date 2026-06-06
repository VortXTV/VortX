import Foundation
import NodeMobile

/// Runs Stremio's streaming server (server.js) inside the app via nodejs-mobile,
/// listening on http://127.0.0.1:11470. This enables torrent / uncached streams
/// (debrid/direct streams play without it). node_start() blocks, so it runs on a
/// dedicated thread with a large stack (Node needs one).
enum NodeServer {
    private(set) static var started = false

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
        NSLog("StremioX: node server exited rc=\(rc)")
    }

    /// JSON-encode a string for safe embedding in the preload JS literal.
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // unwrap the [ ... ] → the quoted string
    }
}
