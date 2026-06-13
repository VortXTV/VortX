#if os(macOS)
import Foundation

/// macOS streaming server. Runs Stremio's server.js (the torrent engine + /proxy + HLS) in a
/// CHILD PROCESS, listening on http://127.0.0.1:11470, so TORRENT streams play on the Mac.
///
/// iOS/tvOS embed `nodejs-mobile` (node as a *library*, started in-process via `node_start`).
/// nodejs-mobile has no macOS slice, so the Mac can't do that. Instead we bundle the ordinary
/// standalone `node` executable (Resources/node-darwin-arm64, fetched by scripts/fetch-node-macos.sh)
/// and spawn it with `Process`. This works because the Mac app is NOT sandboxed — it may launch
/// child processes and bind loopback ports.
///
/// This deliberately exposes the SAME API surface as the iOS/tvOS `NodeServer`
/// (`startIfNeeded()`, `statusDescription`, `logTail(_:)`) under the same type name, so the shared
/// call sites in StremioXiOSApp / iOSSettingsView resolve to the right implementation per platform
/// with no `#if os(macOS)` at the call site.
enum NodeServer {
    private(set) static var started = false
    /// Set when the node process exits. A relaunch (or toggling Direct Links Only off) restarts it.
    private(set) static var exitCode: Int32?

    /// The running child process, kept alive for the app's lifetime (and so we can terminate it).
    private static var process: Process?

    /// One-line state for the Settings diagnostics (mirrors the iOS/tvOS NodeServer wording).
    static var statusDescription: String {
        if PlaybackSettings.torrentsDisabled { return "Disabled by Direct Links Only" }
        if Bundle.main.path(forResource: "node-darwin-arm64", ofType: nil) == nil {
            return "Not started (node binary missing from the bundle)"
        }
        if !started { return "Not started (server.js missing from the bundle)" }
        if let code = exitCode { return "Server exited with code \(code). Relaunch the app to restart it." }
        return "Server process running"
    }

    /// The last lines of the server's own log (console output + crashes are teed to a file).
    static func logTail(_ lines: Int = 4) -> [String] {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map(String.init)
    }

    /// Spawn the node server once. Idempotent. No-op if the node binary or server.js is missing.
    static func startIfNeeded() {
        guard !started else { return }
        guard let nodeBin = Bundle.main.path(forResource: "node-darwin-arm64", ofType: nil) else {
            NSLog("StremioX: node binary not found in bundle, streaming server disabled")
            return
        }
        guard let serverJs = Bundle.main.path(forResource: "server", ofType: "js") else {
            NSLog("StremioX: server.js not found in bundle, streaming server disabled")
            return
        }
        started = true
        spawn(nodeBin: nodeBin, scriptPath: serverJs)
    }

    // MARK: - Private

    /// The server's writable app-data root. The server reads HOME for its cache/settings path; we
    /// point it at a per-user Application Support dir (Caches would be purgeable mid-stream).
    private static var serverHome: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("StremioX").path
    }

    private static var logPath: String {
        (serverHome as NSString).appendingPathComponent("stremio-server.log")
    }

    private static func spawn(nodeBin: String, scriptPath: String) {
        let home = serverHome
        let serverData = (home as NSString).appendingPathComponent("stremio-server")
        try? FileManager.default.createDirectory(atPath: serverData, withIntermediateDirectories: true)

        // Tee console + uncaught errors to a log file (the server's own stdout/stderr are also
        // redirected to it below). Lets a dead/misbehaving server explain itself in Settings.
        let preloadPath = (home as NSString).appendingPathComponent("stremiox-preload.js")
        let preload = """
        const fs=require('fs'),L=\(jsString(logPath));
        const w=(t,a)=>{try{fs.appendFileSync(L,t+' '+Array.prototype.map.call(a,String).join(' ')+'\\n')}catch(e){}};
        process.on('uncaughtException',function(e){w('[uncaught]',[e&&e.stack||e])});
        process.on('unhandledRejection',function(e){w('[rej]',[e&&e.stack||e])});
        w('[boot]',['mac preload active']);
        """
        try? preload.write(toFile: preloadPath, atomically: true, encoding: .utf8)

        // Keep the tail of the previous boot's log instead of wiping it, so a crash that took the
        // whole app down leaves its last lines readable after relaunch. Capped so it can't grow.
        let prior = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let keptTail = prior.count > 48_000 ? String(prior.suffix(48_000)) : prior
        try? (keptTail + "\n===== BOOT =====\n").write(toFile: logPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeBin)
        proc.arguments = ["-r", preloadPath, scriptPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: home)

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home               // server reads HOME for its app-data path
        env["APP_PATH"] = serverData      // torrent cache + settings
        env["NO_CORS"] = "1"
        // Disable Chromecast/DLNA discovery. The native Mac UI has no cast feature, and the
        // server's SSDP multicast loop is pure overhead here. Matches the iOS/tvOS embed config.
        env["CASTING_DISABLED"] = "1"
        // More libuv workers for tracker DNS + the engine's disk/crypto (same rationale as iOS).
        env["UV_THREADPOOL_SIZE"] = "16"
        proc.environment = env

        // Redirect the node process's own stdout/stderr to the same log file we tee console into.
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            proc.standardOutput = fh
            proc.standardError = fh
        }

        proc.terminationHandler = { p in
            exitCode = p.terminationStatus
            NSLog("StremioX: node server exited rc=\(p.terminationStatus)")
        }

        do {
            NSLog("StremioX: starting node streaming server (bin=\(nodeBin), HOME=\(home))")
            try proc.run()
            process = proc
        } catch {
            started = false
            NSLog("StremioX: failed to launch node server: \(error)")
        }
    }

    /// JSON-encode a string for safe embedding in the preload JS literal.
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // unwrap the [ ... ] → the quoted string
    }
}
#endif
