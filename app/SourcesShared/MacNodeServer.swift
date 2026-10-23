#if os(macOS)
import Foundation
import Darwin   // getifaddrs / ifaddrs / getnameinfo for LAN IP discovery
import os

/// Restart-only TERM grace. No numeric PID, force signal, or wait on a possibly live child.
enum MacNodeRestartPolicy {
    static func requestTermination(
        grace: TimeInterval,
        isRunning: () -> Bool,
        terminate: () -> Void,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        guard isRunning() else { return true }
        let deadline = now() + max(0, grace)
        terminate()
        while isRunning() {
            let remaining = deadline - now()
            guard remaining > 0 else { return false }
            pause(min(0.05, remaining))
        }
        return true
    }
}

/// The UI reads this restart-failure snapshot independently of the lifecycle queue.
final class MacNodeRestartStatus: Sendable {
    private struct Failure: Sendable {
        let owner: ObjectIdentifier
        let isRunning: @Sendable () -> Bool
    }
    private let failure = OSAllocatedUnfairLock<Failure?>(initialState: nil)

    func record(owner: AnyObject, isRunning: @escaping @Sendable () -> Bool) {
        let next = Failure(owner: ObjectIdentifier(owner), isRunning: isRunning)
        let previous = failure.withLock { state in
            let previous = state
            state = next
            return previous
        }
        // Retire old captures outside the lock: their deinitializers may re-enter status.
        withExtendedLifetime(previous) {}
    }

    func clear() {
        let previous = failure.withLock { state in
            let previous = state
            state = nil
            return previous
        }
        withExtendedLifetime(previous) {}
    }

    func matches(owner: AnyObject) -> Bool {
        let identity = ObjectIdentifier(owner)
        return failure.withLock { $0?.owner == identity }
    }

    var message: String? {
        let snapshot = failure.withLock { $0 }
        guard let snapshot else { return nil }
        // Never hold our lock across a Foundation Process status read.
        if snapshot.isRunning() {
            return "Restart did not complete: the previous streaming server is still running. Try restarting again."
        }
        return "Restart did not complete: the previous streaming server has exited. Try restarting again."
    }
}

/// macOS streaming server: the VortX engine's `vortx-streaming-server`, bundled from app/Vendor
/// and run as a CHILD PROCESS listening on 127.0.0.1:11470 (all interfaces while LAN sharing is
/// on). The Mac app is not sandboxed, so it may launch child processes and bind loopback ports;
/// iOS/tvOS run the same server in-process instead (`VortxNativeServer`).
///
/// This deliberately exposes the SAME API surface as the iOS/tvOS `NodeServer`
/// (`startIfNeeded()`, `statusDescription`, `logTail(_:)`) under the same type name, so the shared
/// call sites in VortXiOSApp / iOSSettingsView resolve to the right implementation per platform
/// with no `#if os(macOS)` at the call site. A missing server binary is reported explicitly.
enum NodeServer {
    private struct QuitAttempt: Sendable {
        let id: UUID
        let completion: @MainActor @Sendable (Bool) -> Void
        var termAdmitted = false
    }

    /// All mutable static state has checked storage. The lifecycle queue still serializes
    /// process operations; readers and the independent quit deadline never join that queue.
    private struct RuntimeState: Sendable {
        var started = false
        var exitCode: Int32?
        var process: Process?
        var nativePortReceipt: String?
        var nativePublication: (process: Process, receipt: String)?
        var nativeBoundPort: Int?
        var nativeReceiptReadAt: TimeInterval = -1
        var shutdownRequested = false
        var quitAttempt: QuitAttempt?
        var quitFailure: String?
    }
    private static let runtime = OSAllocatedUnfairLock(initialState: RuntimeState())

    private(set) static var started: Bool {
        get { runtime.withLock { $0.started } }
        set { runtime.withLock { $0.started = newValue } }
    }
    private(set) static var exitCode: Int32? {
        get { runtime.withLock { $0.exitCode } }
        set { runtime.withLock { $0.exitCode = newValue } }
    }
    private static var process: Process? {
        get { runtime.withLock { $0.process } }
        set {
            let previous = runtime.withLock { state in
                let previous = state.process
                state.process = newValue
                return previous
            }
            withExtendedLifetime(previous) {}
        }
    }
    private static var nativePortReceipt: String? {
        get { runtime.withLock { $0.nativePortReceipt } }
        set { runtime.withLock { $0.nativePortReceipt = newValue } }
    }
    private static var shutdownRequested: Bool {
        runtime.withLock { $0.shutdownRequested }
    }

    /// Serializes launch/restart/termination operations. No public reader or AppKit quit hook
    /// synchronously joins this queue. A launch/helper/Foundation call can still stall it;
    /// the independent quit deadline then cancels quit while the app keeps its child handle.
    private static let queue = DispatchQueue(label: "com.stremiox.mac.nodeserver")
    private static let restartStatus = MacNodeRestartStatus()

    /// TERM grace; it does not authorize a numeric-PID force signal or an unbounded wait.
    private static let terminateGrace: TimeInterval = 2.0
    /// Ordinary quit gives the native child's 3 s graceful + 1 s runtime-stop path margin.
    /// Restart keeps its separately reviewed two-second grace and explicit retry behavior.
    private static let quitGrace: TimeInterval = 5.0

    // MARK: - LAN sharing ("act as a server for others on this network")

    /// UserDefaults key for the "Share streaming server on this network" toggle.
    private static let shareKey = "stremiox.mac.shareServerOnLAN"

    /// When ON, the bundled server binds 0.0.0.0 (all interfaces) so other devices on the LAN
    /// (your Apple TV / phone) can use this Mac as their streaming server. When OFF (the
    /// default), it binds loopback only (127.0.0.1), invisible to the network. Changing this
    /// restarts the server so the new bind takes effect.
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
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

    // MARK: - Native server

    /// The bundled server binary (a script-produced, gitignored artifact, app/Vendor/
    /// vortx-streaming-server, embedded by the project's post-build step), or nil when missing.
    private static var nativeServerBinary: String? {
        Bundle.main.path(forResource: "vortx-streaming-server", ofType: nil)
    }

    /// Publication requires this exact child to be running AND to have bound its socket. A stale
    /// listener on 11470 cannot become the endpoint while the child retries its bind.
    static var nativeBaseURL: String? {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = runtime.withLock { state -> (Process, String, Int?, Bool)? in
            guard !state.shutdownRequested, let published = state.nativePublication else { return nil }
            let mayRead = state.nativeBoundPort == nil &&
                (state.nativeReceiptReadAt < 0 || now - state.nativeReceiptReadAt >= 0.5)
            if mayRead { state.nativeReceiptReadAt = now }
            return (published.process, published.receipt, state.nativeBoundPort, mayRead)
        }
        guard let (child, receiptPath, cachedPort, mayRead) = snapshot,
              child.isRunning else { return nil }
        if let port = cachedPort { return "http://127.0.0.1:\(port)" }
        guard mayRead else { return nil }
        // Foundation status and filesystem I/O never execute while holding runtime's lock.
        let receipt = try? String(contentsOfFile: receiptPath, encoding: .utf8)
        guard let port = NativeTransportPolicy.boundNativePort(processRunning: true, receipt: receipt) else { return nil }
        let stillPublished = runtime.withLock { state in
            guard !state.shutdownRequested, let published = state.nativePublication,
                  published.process === child, published.receipt == receiptPath else { return false }
            state.nativeBoundPort = port
            return true
        }
        guard stillPublished, child.isRunning else { return nil }
        return "http://127.0.0.1:\(port)"
    }

    private static func publishNativeProcess(_ process: Process?, receipt: String? = nil) {
        let previous = runtime.withLock { state in
            let previous = state.nativePublication
            if let process, let receipt { state.nativePublication = (process, receipt) }
            else { state.nativePublication = nil }
            state.nativeBoundPort = nil
            state.nativeReceiptReadAt = -1
            return previous
        }
        withExtendedLifetime(previous) {}
    }

    /// Locate an ffmpeg/ffprobe pair for VideoToolbox transcoding. Only existence is checked
    /// here (Settings hint and the engine-host transcode capability); nothing is executed.
    private static func ffmpegBinaries() -> (ffmpeg: String, ffprobe: String)? {
        // System path first: Homebrew prefixes are world-writable on many Macs.
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
    static var canTranscode: Bool { ffmpegBinaries() != nil }

    /// Checked restart-only snapshot for UI readers; never joins the lifecycle queue or reads
    /// the unrelated started/exitCode state. A retained child's late exit changes this message.
    static var restartFailureDescription: String? { restartStatus.message }

    /// One-line state for the Settings diagnostics.
    static var statusDescription: String {
        if PlaybackSettings.torrentsDisabled { return "Disabled by Direct Links Only" }
        let status = runtime.withLock { ($0.started, $0.exitCode, $0.quitFailure) }
        if let failure = status.2 { return failure }
        if let message = restartFailureDescription { return message }
        if nativeServerBinary == nil { return "Native streaming server is missing from this build." }
        if !status.0 { return "Not started (native server)" }
        if let code = status.1 { return "Native server exited with code \(code). Relaunch the app to restart it." }
        if sharedOnLAN, let url = lanURL { return "Sharing on this network at \(url) (native server)" }
        return "Native server process running"
    }

    /// The last lines of the server's own log (console output + crashes are teed to a file).
    static func logTail(_ lines: Int = 4) -> [String] {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map(String.init)
    }

    /// Spawn the server once. Idempotent. No-op if the server binary is missing (reported by
    /// statusDescription) or if the app is already shutting down (so a late call can't resurrect
    /// a killed server).
    static func startIfNeeded() {
        // Wire the shared diagnostics indirection so the VXProbe heartbeat + the diagnostics export can
        // surface this server's state without SourcesShared referencing a concrete NodeServer. Idempotent.
        ServerDiagnostics.register(status: { statusDescription }, logTail: { logTail($0) })
        queue.async {
            guard !started, !shutdownRequested else { return }
            guard let nativeBin = nativeServerBinary else {
                DiagnosticsLog.log("server", "native streaming selected but server binary is missing")
                return
            }
            // A prior run that was force-killed / crashed before `stop()` could fire may have left a
            // server child reparented to launchd, still holding 11470. Clear that stale orphan before
            // we spawn, so this launch gets a free port instead of a server that can't bind.
            reclaimStalePort()
            started = true
            spawnNative(binPath: nativeBin)
        }
    }

    /// Terminate the running server process (if any) and relaunch it. Used when the LAN-sharing
    /// toggle flips, so the new bind (loopback vs all-interfaces) takes effect without an app
    /// restart. No-op if the server was never eligible to start (missing binary / disabled) or if
    /// the app is shutting down. This is a RESTART, NOT a shutdown: it does NOT set
    /// `shutdownRequested`, so the server comes back up afterwards.
    static func restart() {
        queue.async {
            guard !shutdownRequested, !PlaybackSettings.torrentsDisabled else { return }
            runtime.withLock { $0.quitFailure = nil }
            func reapCurrent() -> Bool {
                publishNativeProcess(nil)
                if let proc = process {
                    proc.terminationHandler = nil   // expected stop; don't surface it as a crash
                    guard MacNodeRestartPolicy.requestTermination(
                        grace: terminateGrace,
                        isRunning: { proc.isRunning },
                        terminate: { proc.terminate() }
                    ) else {
                        // Retain this exact child and receipt. A later retry/stop still owns it;
                        // a replacement must not overwrite ownership or assume the port is free.
                        restartStatus.record(owner: proc, isRunning: { proc.isRunning })
                        DiagnosticsLog.log("server", "restart did not complete within TERM grace; existing child retained")
                        return false
                    }
                }
                process = nil
                exitCode = nil
                retireNativePortReceipt()
                restartStatus.clear()
                return true
            }
            guard reapCurrent() else { return }
            started = false
            guard let nativeBin = nativeServerBinary else {
                DiagnosticsLog.log("server", "native streaming selected but server binary is missing")
                return
            }
            started = true
            spawnNative(binPath: nativeBin)
        }
    }

    /// Ask AppKit to defer quit while this request observes the exact child exiting. A deadline
    /// replies false and restores normal operation; it never discards a live child or its receipt.
    /// The callback fires once for this attempt, even if launch/TERM outlives the deadline.
    static func stop(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let id = UUID()
        let accepted = runtime.withLock { state in
            guard state.quitAttempt == nil else { return false }
            state.quitAttempt = QuitAttempt(id: id, completion: completion)
            state.shutdownRequested = true
            state.quitFailure = nil
            return true
        }
        guard accepted else {
            Task { @MainActor in completion(false) }
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + quitGrace
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + quitGrace + 0.25) {
            _ = completeQuitAttempt(id, stopped: false, owner: nil)
        }
        queue.async {
            guard runtime.withLock({ $0.quitAttempt?.id == id }) else { return }
            guard let proc = process else {
                _ = completeQuitAttempt(id, stopped: true, owner: nil)
                return
            }
            let previousHandler = proc.terminationHandler
            proc.terminationHandler = nil
            let stopped = MacNodeRestartPolicy.requestTermination(
                grace: max(0, deadline - ProcessInfo.processInfo.systemUptime),
                isRunning: { proc.isRunning },
                terminate: {
                    // Liveness/handler access above may have outlived this quit attempt.
                    // Claim this exact action only now, then leave the lock before Foundation.
                    guard admitQuitTermination(id, owner: proc) else { return }
                    // Admission is irrevocable: cancellation can win after this check but
                    // cannot retract the Foundation call already admitted for this child.
                    proc.terminate()
                }
            )
            let resolved = completeQuitAttempt(id, stopped: stopped, owner: proc)
            // A cancelled attempt may already have issued TERM. Restore observation for the
            // retained child; a late exit is recorded without acknowledging an old quit request.
            if (!resolved || !stopped), process === proc {
                proc.terminationHandler = previousHandler
                if !proc.isRunning {
                    exitCode = proc.terminationStatus
                    retireNativePortReceipt()
                    DiagnosticsLog.log("server", "child exited after quit was cancelled; retry Quit or Restart streaming server")
                }
            }
        }
    }

    /// Admit at most one TERM for the exact active quit and child. No Process method, status
    /// getter, or callback runs under this lock. The caller must invoke the admitted action
    /// outside the lock; a later cancellation cannot retract that already-admitted action.
    private static func admitQuitTermination(_ id: UUID, owner: Process) -> Bool {
        runtime.withLock { state in
            guard state.shutdownRequested,
                  var attempt = state.quitAttempt, attempt.id == id,
                  state.process === owner, !attempt.termAdmitted else { return false }
            attempt.termAdmitted = true
            state.quitAttempt = attempt
            return true
        }
    }

    /// Winner selection and the quit fence share the same lock as the child owner. Old timers
    /// and late queue completions cannot clear a newer attempt, change its fence, or reply twice.
    @discardableResult
    private static func completeQuitAttempt(_ id: UUID, stopped: Bool, owner: Process?) -> Bool {
        let resolution = runtime.withLock { state -> (QuitAttempt, String?, Process?)? in
            guard let attempt = state.quitAttempt, attempt.id == id else { return nil }
            if stopped, state.process !== owner { return nil }
            let retained = state.process
            state.quitAttempt = nil
            if stopped {
                let receipt = state.nativePortReceipt
                state.shutdownRequested = true
                state.started = false
                state.exitCode = nil
                state.process = nil
                state.nativePortReceipt = nil
                state.nativePublication = nil
                state.nativeBoundPort = nil
                state.nativeReceiptReadAt = -1
                state.quitFailure = nil
                return (attempt, receipt, retained)
            }
            state.shutdownRequested = false
            state.quitFailure = "Quit was canceled because streaming-server shutdown was not confirmed. You can retry Quit."
            // Publication stayed retained behind the quit fence. Canceling exposes that same
            // snapshot, never inventing a publication suppressed by an earlier failed restart.
            return (attempt, nil, retained)
        }
        guard let resolution else { return false }
        let completion = resolution.0.completion
        Task { @MainActor in completion(stopped) }
        // The reply depends on observed child exit, not filesystem cleanup. Never hold the
        // state lock across FileManager or across the release of a retained Process/callback.
        if stopped {
            restartStatus.clear()
            if let receipt = resolution.1 { try? FileManager.default.removeItem(atPath: receipt) }
        }
        withExtendedLifetime(resolution.2) {}
        return true
    }

    /// Park ownership before Foundation launch can block or the child can exit. A queued quit
    /// suppresses launch; a canceled quit restores the ability to start normally.
    private static func beginLaunch(_ child: Process) -> Bool {
        runtime.withLock { state in
            guard !state.shutdownRequested, state.process == nil else { return false }
            state.process = child
            return true
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

    /// Reclaim port 11470 if a STALE copy of OUR OWN streaming server is still holding it, e.g. a
    /// prior run that was force-killed / crashed before `stop()` could fire, leaving the child
    /// reparented to launchd (PPID 1). We match "ours" narrowly, by the `vortx-streaming-server`
    /// binary name in its argv, so an unrelated process that merely happens to hold the port is
    /// left untouched (the server then fails to bind and Settings surfaces the exit, rather than
    /// killing a stranger). SIGTERM first, escalate to SIGKILL, mirroring `stop()`. Cheap on the
    /// common path: a free port costs one `lsof` that returns nothing.
    private static func reclaimStalePort() {
        for pid in listeners(onPort: 11470) where isOurStreamingServer(pid) {
            NSLog("%@", "StremioX: reclaiming port 11470 from a stale streaming server (pid \(pid))")
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

    /// True if `pid` is OUR streaming server: the `vortx-streaming-server` binary name in its argv,
    /// read via `ps -o command=`.
    private static func isOurStreamingServer(_ pid: pid_t) -> Bool {
        let command = runTool("/bin/ps", ["-o", "command=", "-p", String(pid)]) ?? ""
        return command.contains("vortx-streaming-server")
    }

    /// `kill(pid, 0)` probes for existence without delivering a signal: success ⇒ the process is alive.
    private static func pidIsAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Run a short helper tool to completion and return its stdout (nil on launch failure). Used only
    /// for the small, bounded `lsof`/`ps` probes above; output is tiny, so reading then waiting can't
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

    /// Spawn the streaming server (`vortx-streaming-server`): spawn here, SIGTERM via
    /// stop()/restart(), crash surfaced by the terminationHandler, stdout/stderr teed into the
    /// Settings log. It exits cleanly on SIGTERM; a crash orphan is cleared by reclaimStalePort on
    /// the next launch, and its deterministic 11470 bind retries instead of drifting ports.
    private static func spawnNative(binPath: String) {
        let home = serverHome
        let serverData = (home as NSString).appendingPathComponent("stremio-server")
        try? FileManager.default.createDirectory(atPath: serverData, withIntermediateDirectories: true)

        // Keep the tail of the previous boot's log instead of wiping it, so a crash that took the
        // whole app down leaves its last lines readable after relaunch. Capped so it can't grow.
        let prior = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let keptTail = prior.count > 48_000 ? String(prior.suffix(48_000)) : prior
        try? (keptTail + "\n===== BOOT (native) =====\n").write(toFile: logPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: home)

        // The native server's whole config is environment (see the engine's
        // crates/streaming-server/src/main.rs):
        //   VORTX_SERVER_HOME  data root (settings.json + stremio-cache/) under
        //                      <AppSupport>/StremioX/stremio-server
        //   VORTX_PORT_FILE    a unique per-launch bind receipt, read before publishing the endpoint
        //   VORTX_SERVER_PORT fixed 11470, overriding an inherited development port
        //   VORTX_BIND         0.0.0.0 (LAN sharing ON) vs 127.0.0.1 (private, the default)
        //   VORTX_LAN_IP       the advertised /settings baseUrl host while sharing
        // It binds 11470 DETERMINISTICALLY (bounded retry, then exit nonzero; never drifts to
        // 11471+), so lanURL's fixed :11470 and StremioServer.embedded stay correct.
        var env = NativeTransportPolicy.nativeServerEnvironment(from: ProcessInfo.processInfo.environment)
        env["VORTX_SERVER_HOME"] = serverData
        retireNativePortReceipt()
        nativePortReceipt = (home as NSString).appendingPathComponent("native-server-\(UUID().uuidString).port")
        env["VORTX_PORT_FILE"] = nativePortReceipt
        env["VORTX_SERVER_PORT"] = "11470"
        if sharedOnLAN {
            env["VORTX_BIND"] = "0.0.0.0"
            if let ip = lanIP { env["VORTX_LAN_IP"] = ip }
        } else {
            env["VORTX_BIND"] = "127.0.0.1"
        }
        proc.environment = env

        // Tee the server's stdout/stderr into the same log file Settings reads (logTail).
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            proc.standardOutput = fh
            proc.standardError = fh
        }

        // Fires only for an UNEXPECTED exit (stop()/restart() detach it first), routed through
        // the serial queue so the state write is race-free, and ignored once shutdown began.
        proc.terminationHandler = { p in
            queue.async {
                guard !shutdownRequested, process === p,
                      !restartStatus.matches(owner: p) else { return }
                exitCode = p.terminationStatus
                retireNativePortReceipt()
                NSLog("%@", "StremioX: native streaming server exited rc=\(p.terminationStatus)")
                DiagnosticsLog.log("server", "native server exited rc=\(p.terminationStatus) (unexpected; relaunch to restart)")
            }
        }

        do {
            NSLog("%@", "StremioX: starting native streaming server (bin=\(binPath), home=\(serverData))")
            guard beginLaunch(proc) else {
                started = false
                retireNativePortReceipt()
                return
            }
            try proc.run()
            publishNativeProcess(proc, receipt: nativePortReceipt)
        } catch {
            if process === proc { process = nil }
            started = false
            retireNativePortReceipt()
            NSLog("%@", "StremioX: failed to launch native streaming server: \(error)")
        }
    }

    /// Queue-only cleanup after the owning process was observed exited or failed to launch.
    private static func retireNativePortReceipt() {
        publishNativeProcess(nil)
        guard let path = nativePortReceipt else { return }
        nativePortReceipt = nil
        try? FileManager.default.removeItem(atPath: path)
    }

}
#endif
