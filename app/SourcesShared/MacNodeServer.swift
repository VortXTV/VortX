#if os(macOS)
import Foundation
import Darwin   // getifaddrs / ifaddrs / getnameinfo for LAN IP discovery

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
/// call sites in VortXiOSApp / iOSSettingsView resolve to the right implementation per platform
/// with no `#if os(macOS)` at the call site.
enum NodeServer {
    private(set) static var started = false
    /// Set when the node process exits. A relaunch (or toggling Direct Links Only off) restarts it.
    private(set) static var exitCode: Int32?

    /// The running child process, kept alive for the app's lifetime (and so we can terminate it).
    private static var process: Process?

    /// Serializes all access to the mutable child state (`process`, `started`, `exitCode`,
    /// `shutdownRequested`). startIfNeeded/restart dispatch their work to this queue ASYNC so neither
    /// app launch (which runs `reclaimStalePort`'s lsof/ps) nor the LAN-sharing toggle (which reaps
    /// and respawns the child) ever blocks the main thread; stop() runs synchronously because it must
    /// finish reaping the child before the app process exits. The process's terminationHandler fires
    /// on an arbitrary background thread. Funnelling every mutation through one serial queue keeps
    /// them race-free without sprinkling locks. Matches the serial-queue pattern used elsewhere in
    /// the shared sources (DiagnosticsLog, Keychain).
    private static let queue = DispatchQueue(label: "com.stremiox.mac.nodeserver")

    /// Set by `stop()` so the terminationHandler treats the kill as an intentional app-exit
    /// shutdown — NOT a crash to surface in Settings. A `restart()` does NOT set this (it nils the
    /// handler before terminating, so the handler never fires for a restart). Once set, the server
    /// is considered down for good for this process lifetime.
    private static var shutdownRequested = false

    /// How long we wait for the child to exit after SIGTERM before escalating to SIGKILL on app
    /// quit. Foundation's `Process.terminate()` sends SIGTERM, which a wedged node may ignore; the
    /// SIGKILL escalation guarantees the port is released and nothing is reparented to launchd.
    private static let terminateGrace: TimeInterval = 2.0

    // MARK: - LAN sharing ("act as a server for others on this network")

    /// UserDefaults key for the "Share streaming server on this network" toggle.
    private static let shareKey = "stremiox.mac.shareServerOnLAN"

    /// When ON, the bundled server binds 0.0.0.0 (all interfaces) so other devices on the LAN
    /// (your Apple TV / phone) can use this Mac as their Stremio streaming server. When OFF
    /// (the default), it binds loopback only (127.0.0.1) — the original behaviour, invisible to
    /// the network. Changing this restarts the node process so the new bind takes effect.
    static var sharedOnLAN: Bool {
        get { UserDefaults.standard.bool(forKey: shareKey) }
        set {
            guard newValue != sharedOnLAN else { return }
            UserDefaults.standard.set(newValue, forKey: shareKey)
            restart()
        }
    }

    /// This machine's primary LAN IPv4 address (e.g. 192.168.1.50), or nil if not on a network.
    /// Prefers en0/en1 (Wi-Fi / Ethernet); skips loopback, link-local (169.254/fe80) and down ifaces.
    static var lanIP: String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        // Rank candidates: prefer en* (Wi-Fi/Ethernet) over anything else.
        var best: (rank: Int, ip: String)?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  flags & IFF_LOOPBACK == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254"), !ip.isEmpty else { continue }   // skip link-local

            let rank = name.hasPrefix("en") ? 0 : 1
            if best == nil || rank < best!.rank { best = (rank, ip) }
        }
        return best?.ip
    }

    /// The LAN URL other devices paste into their server config, when sharing is on and we have an IP.
    static var lanURL: String? {
        guard sharedOnLAN, let ip = lanIP else { return nil }
        return "http://\(ip):11470"
    }

    /// Locate an ffmpeg/ffprobe pair the server can use for VideoToolbox transcoding. server.js
    /// searches a fixed set of paths but NOT Homebrew's Apple-silicon prefix (/opt/homebrew/bin),
    /// so on most Macs it finds nothing and transcoding silently no-ops. We probe the common
    /// locations and, when found, hand the pair to node via FFMPEG_BIN / FFPROBE_BIN (the first
    /// entries server.js honours). With ffmpeg present, server.js auto-detects the macOS
    /// `videotoolbox` hw-accel profile on boot and uses h264_videotoolbox / hevc_videotoolbox.
    private static func ffmpegBinaries() -> (ffmpeg: String, ffprobe: String)? {
        // SECURITY NOTE: we hand whichever ffmpeg/ffprobe we find here to node, which
        // execs it for transcoding. There is no signature/ownership check, so we trust
        // whatever sits at these paths. Homebrew prefixes are world-writable on many
        // Macs, so we probe the system path (/usr/bin) FIRST and only fall back to a
        // Homebrew-installed binary when the system has none (macOS ships no ffmpeg by
        // default, so the Homebrew fallback is what actually enables transcoding).
        let prefixes = [
            "/usr/bin",            // system (preferred: not world-writable)
            "/opt/homebrew/bin",   // Homebrew, Apple silicon
            "/usr/local/bin",      // Homebrew, Intel / manual installs
        ]
        let fm = FileManager.default
        for prefix in prefixes {
            let ff = "\(prefix)/ffmpeg", fp = "\(prefix)/ffprobe"
            if fm.isExecutableFile(atPath: ff) && fm.isExecutableFile(atPath: fp) {
                return (ff, fp)
            }
        }
        return nil
    }

    /// Whether VideoToolbox transcoding can run: a discoverable ffmpeg/ffprobe pair exists.
    /// (server.js always carries the darwin `videotoolbox` profile and enables it by default.)
    static var canTranscode: Bool { ffmpegBinaries() != nil }

    /// One-line state for the Settings diagnostics (mirrors the iOS/tvOS NodeServer wording).
    static var statusDescription: String {
        if PlaybackSettings.torrentsDisabled { return "Disabled by Direct Links Only" }
        if Bundle.main.path(forResource: "node-darwin-arm64", ofType: nil) == nil {
            return "Not started (node binary missing from the bundle)"
        }
        if !started { return "Not started (server.js missing from the bundle)" }
        if let code = exitCode { return "Server exited with code \(code). Relaunch the app to restart it." }
        if sharedOnLAN, let url = lanURL { return "Sharing on this network at \(url)" }
        return "Server process running"
    }

    /// The last lines of the server's own log (console output + crashes are teed to a file).
    static func logTail(_ lines: Int = 4) -> [String] {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map(String.init)
    }

    /// Spawn the node server once. Idempotent. No-op if the node binary or server.js is missing,
    /// or if the app is already shutting down (so a late call can't resurrect a killed server).
    static func startIfNeeded() {
        // Wire the shared diagnostics indirection so the VXProbe heartbeat + the diagnostics export can
        // surface this server's state without SourcesShared referencing a concrete NodeServer. Idempotent.
        ServerDiagnostics.register(status: { statusDescription }, logTail: { logTail($0) })
        queue.async {
            guard !started, !shutdownRequested else { return }
            guard let nodeBin = Bundle.main.path(forResource: "node-darwin-arm64", ofType: nil) else {
                NSLog("StremioX: node binary not found in bundle, streaming server disabled")
                return
            }
            guard let serverJs = Bundle.main.path(forResource: "server", ofType: "js") else {
                NSLog("StremioX: server.js not found in bundle, streaming server disabled")
                return
            }
            // A prior run that was force-killed / crashed before `stop()` could fire may have left a
            // node child reparented to launchd, still holding 11470. Clear that stale orphan before we
            // spawn, so this launch gets a free port instead of a server that can't bind.
            reclaimStalePort()
            started = true
            spawn(nodeBin: nodeBin, scriptPath: serverJs)
        }
    }

    /// Terminate the running node process (if any) and relaunch it. Used when the LAN-sharing
    /// toggle flips, so the new bind (loopback vs all-interfaces) takes effect without an app
    /// restart. No-op if the server was never eligible to start (missing binary / disabled) or if
    /// the app is shutting down. This is a RESTART, NOT a shutdown: it does NOT set
    /// `shutdownRequested`, so the server comes back up afterwards.
    static func restart() {
        queue.async {
            guard !shutdownRequested,
                  !PlaybackSettings.torrentsDisabled,
                  let nodeBin = Bundle.main.path(forResource: "node-darwin-arm64", ofType: nil),
                  let serverJs = Bundle.main.path(forResource: "server", ofType: "js") else { return }
            if let proc = process, proc.isRunning {
                proc.terminationHandler = nil   // expected stop; don't surface it as a crash
                proc.terminate()
                proc.waitUntilExit()            // reap, so the relaunch can rebind 11470 cleanly
            }
            process = nil
            exitCode = nil
            started = true
            spawn(nodeBin: nodeBin, scriptPath: serverJs)
        }
    }

    /// Force-terminate the running node child and stop the server for this process lifetime. Called
    /// on app termination (see VortXiOSApp's macOS app-delegate hook) so the child never gets
    /// reparented to launchd holding port 11470. Idempotent and thread-safe.
    ///
    /// Foundation's `Process` does NOT kill its child when the parent exits, so without this an app
    /// quit leaks the node process. We send SIGTERM (`terminate()`), give it a short grace, then
    /// escalate to SIGKILL for any wedged child, and `waitUntilExit()` to reap it (no zombie).
    static func stop() {
        queue.sync {
            shutdownRequested = true        // mark intentional: the terminationHandler must not treat this as a crash
            started = false
            guard let proc = process else { return }
            process = nil

            // Detach the crash handler first: this exit is expected, not a failure to surface.
            proc.terminationHandler = nil
            guard proc.isRunning else { return }

            proc.terminate()                // SIGTERM — ask node to exit cleanly
            // Escalate to SIGKILL if it ignores SIGTERM, so the port is always released and nothing
            // is reparented to launchd. `waitUntilExit()` then reaps the child (no zombie).
            let deadline = Date().addingTimeInterval(terminateGrace)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            proc.waitUntilExit()
            NSLog("StremioX: node streaming server stopped on app termination")
        }
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

    // MARK: - Stale-port reclaim

    /// Reclaim port 11470 if a STALE copy of OUR OWN node server is still holding it — e.g. a prior
    /// run that was force-killed / crashed before `stop()` could fire, leaving the child reparented to
    /// launchd (PPID 1). The preload's parent-death watchdog stops new orphans from forming; this
    /// clears any that predate it (or slipped through its ~1s poll window). We match "ours" narrowly —
    /// a process whose argv references the `stremiox-preload.js` we inject, a marker nothing else uses
    /// — so an unrelated process that merely happens to hold the port is left untouched (we log it and
    /// let server.js fail to bind, surfacing the exit in Settings, rather than killing a stranger).
    /// SIGTERM first, escalate to SIGKILL, mirroring `stop()`. Cheap on the common path: a free port
    /// costs one `lsof` that returns nothing.
    private static func reclaimStalePort() {
        for pid in listeners(onPort: 11470) where isOurNodeServer(pid) {
            NSLog("%@", "StremioX: reclaiming port 11470 from a stale node server (pid \(pid))")
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(terminateGrace)
            while pidIsAlive(pid) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if pidIsAlive(pid) { kill(pid, SIGKILL) }
        }
    }

    /// PIDs holding a LISTEN socket on `port` (via `lsof`); empty when the port is free. Any failure to
    /// run or parse `lsof` yields no PIDs, so we simply skip reclaiming.
    private static func listeners(onPort port: Int) -> [pid_t] {
        let out = runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) ?? ""
        return out.split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// True if `pid` is one of our embedded node servers, identified by the `stremiox-preload.js`
    /// marker in its argv (read via `ps -o command=`).
    private static func isOurNodeServer(_ pid: pid_t) -> Bool {
        (runTool("/bin/ps", ["-o", "command=", "-p", String(pid)]) ?? "").contains("stremiox-preload.js")
    }

    /// `kill(pid, 0)` probes for existence without delivering a signal: success ⇒ the process is alive.
    private static func pidIsAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Run a short helper tool to completion and return its stdout (nil on launch failure). Used only
    /// for the small, bounded `lsof`/`ps` probes above — output is tiny, so reading then waiting can't
    /// deadlock on a full pipe.
    private static func runTool(_ launchPath: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func spawn(nodeBin: String, scriptPath: String) {
        let home = serverHome
        let serverData = (home as NSString).appendingPathComponent("stremio-server")
        try? FileManager.default.createDirectory(atPath: serverData, withIntermediateDirectories: true)

        // Tee console + uncaught errors to a log file (the server's own stdout/stderr are also
        // redirected to it below). Lets a dead/misbehaving server explain itself in Settings.
        //
        // It also gates the bind address: server.js always calls `server.listen(port)` with no
        // host, which Node interprets as 0.0.0.0 (every interface) -- i.e. ALWAYS LAN-reachable.
        // We don't want that unless the user opted in. The preload monkeypatches
        // net.Server.prototype.listen so that, when sharing is OFF, any host-less listen is
        // pinned to 127.0.0.1 (loopback only, the original private behaviour). When sharing is
        // ON we leave Node's default, so the Mac serves the whole LAN. The server still computes
        // its own enginefs.baseUrl from ip.address(), which we surface in Settings as the LAN URL.
        //
        // Third, it installs a parent-death watchdog. `applicationWillTerminate` -> stop() only fires
        // on a CLEAN quit; on a crash / Force Quit / SIGKILL the app dies without it, and Foundation
        // does NOT signal this child, so it gets reparented to launchd and keeps holding 11470 forever
        // (the orphaned-:11470 leak). The watchdog records our parent pid and exits the child the
        // moment it changes — i.e. once we've been reparented — releasing the port within ~1s.
        let bindHost = sharedOnLAN ? "0.0.0.0" : "127.0.0.1"
        let preloadPath = (home as NSString).appendingPathComponent("stremiox-preload.js")
        let preload = """
        const fs=require('fs'),L=\(jsString(logPath));
        const w=(t,a)=>{try{fs.appendFileSync(L,t+' '+Array.prototype.map.call(a,String).join(' ')+'\\n')}catch(e){}};
        process.on('uncaughtException',function(e){w('[uncaught]',[e&&e.stack||e])});
        process.on('unhandledRejection',function(e){w('[rej]',[e&&e.stack||e])});
        try{
          const net=require('net'),HOST=\(jsString(bindHost)),orig=net.Server.prototype.listen;
          net.Server.prototype.listen=function(){
            const a=Array.prototype.slice.call(arguments);
            // Only rewrite the simple `listen(port[, cb])` form server.js uses for the HTTP(S)
            // endpoints. If a host (string 2nd arg) or an options object is already given, leave it.
            if(typeof a[0]==='number' && (a.length===1 || typeof a[1]==='function')){
              const cb=a[1]; a[1]=HOST; if(cb)a[2]=cb;
              w('[bind]',['listen',a[0],'->',HOST]);
            }
            return orig.apply(this,a);
          };
          w('[boot]',['mac preload active; bind='+HOST]);
        }catch(e){w('[bind-err]',[e&&e.stack||e]);}
        // parent-death watchdog (see the Swift note above): if the app dies WITHOUT calling stop()
        // (crash / Force Quit / SIGKILL), Foundation reparents us to launchd and we'd keep holding
        // 11470. Exit once our parent pid changes so the orphaned port is always released. .unref()
        // keeps this poll timer from holding the process open on its own.
        const PPID0=process.ppid;
        setInterval(function(){if(process.ppid!==PPID0){w('[watchdog]',['parent gone; exiting']);process.exit(0);}},1000).unref();
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
        // Point the server at a real ffmpeg/ffprobe so HLS transcoding works and VideoToolbox
        // hardware acceleration (h264_videotoolbox / hevc_videotoolbox) kicks in. server.js's
        // built-in search misses Homebrew's Apple-silicon prefix, so without this it finds no
        // ffmpeg and transcoding is a silent no-op. FFMPEG_BIN / FFPROBE_BIN are the first paths
        // server.js consults. With ffmpeg present it auto-profiles the darwin `videotoolbox`
        // hw-accel on boot (transcodeHardwareAccel defaults on) and uses the GPU encoders.
        if let bins = ffmpegBinaries() {
            env["FFMPEG_BIN"] = bins.ffmpeg
            env["FFPROBE_BIN"] = bins.ffprobe
            NSLog("%@", "StremioX: ffmpeg for transcoding: \(bins.ffmpeg) (VideoToolbox hw-accel)")
        } else {
            NSLog("StremioX: no ffmpeg found; HLS transcoding disabled (install via `brew install ffmpeg`)")
        }
        proc.environment = env

        // Redirect the node process's own stdout/stderr to the same log file we tee console into.
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            proc.standardOutput = fh
            proc.standardError = fh
        }

        // Fires on a background thread only for an UNEXPECTED exit (crash): stop()/restart() detach
        // this handler before terminating, so an intentional kill never lands here. Route through
        // the serial queue so the state write is race-free, and ignore it once shutdown began.
        proc.terminationHandler = { p in
            queue.async {
                guard !shutdownRequested else { return }
                exitCode = p.terminationStatus
                NSLog("%@", "StremioX: node server exited rc=\(p.terminationStatus)")
                // Mirror the unexpected exit into the EXPORTABLE diagnostics log so a server death is visible
                // in the file the owner actually sends, not just the unified log.
                DiagnosticsLog.log("server", "node child exited rc=\(p.terminationStatus) (unexpected; relaunch to restart)")
            }
        }

        do {
            NSLog("%@", "StremioX: starting node streaming server (bin=\(nodeBin), HOME=\(home))")
            try proc.run()
            process = proc
        } catch {
            started = false
            NSLog("%@", "StremioX: failed to launch node server: \(error)")
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
