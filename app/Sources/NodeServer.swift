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

        // The bundled, pinned stremio-web build (built by scripts/build-web.sh as a folder reference).
        let webDir = (Bundle.main.resourcePath as NSString?)?.appendingPathComponent("web") ?? ""

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

        // Serve the bundled, pinned stremio-web (v5) on http://127.0.0.1:11471. Loopback is a secure
        // context (Service Workers / WASM / crypto all work) on the http scheme, so the page and its
        // workers reach the streaming server at http://127.0.0.1:11470 with no mixed-content block.
        // We serve a local pinned build instead of proxying web.stremio.com, which now serves v6 and
        // no longer runs in our WKWebView host.
        (function () {
          try {
            var http = require('http'), fs = require('fs'), path = require('path');
            var ROOT = \(jsString(webDir));
            var MIME = { '.html':'text/html','.js':'text/javascript','.mjs':'text/javascript',
              '.css':'text/css','.json':'application/json','.wasm':'application/wasm','.png':'image/png',
              '.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.svg':'image/svg+xml',
              '.ico':'image/x-icon','.woff':'font/woff','.woff2':'font/woff2','.ttf':'font/ttf',
              '.map':'application/json','.txt':'text/plain','.webmanifest':'application/manifest+json' };
            function send(res, file) {
              fs.readFile(file, function (e, data) {
                if (e) { res.writeHead(404); res.end('not found'); return; }
                res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
                res.end(data);
              });
            }
            http.createServer(function (req, res) {
              var p = decodeURIComponent((req.url || '/').split('?')[0]);
              var file = path.normalize(path.join(ROOT, p));
              if (file.lastIndexOf(ROOT, 0) !== 0) { res.writeHead(403); res.end('no'); return; }  // no traversal
              fs.stat(file, function (e, st) {
                if (!e && st.isFile()) send(res, file);
                else if (!e && st.isDirectory()) send(res, path.join(file, 'index.html'));
                else send(res, path.join(ROOT, 'index.html'));   // SPA fallback for client-side routes
              });
            }).listen(11471, '127.0.0.1', function () { w('[web]', ['bundled stremio-web on 11471 from ' + ROOT]); });
          } catch (e) { w('[web-err]', [String(e)]); }
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
