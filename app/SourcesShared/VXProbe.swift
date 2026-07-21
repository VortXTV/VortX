import Foundation

/// Unified, gated diagnostic-logging facility. When enabled it lets a Terminal-launched (or
/// Settings-toggled) run narrate what the app is doing: point-in-time events plus a once-a-second
/// heartbeat carrying uptime, resident memory, and a compact snapshot of the current screen and
/// player. Off by default, so shipping builds pay nothing.
///
/// Two ways to turn it on:
///  - Launch with the environment variable VORTX_PROBE=1 (Xcode scheme or a Terminal-launched run).
///  - Flip the "Diagnostic logging" toggle in Settings, which writes UserDefaults key
///    "stremiox.probeLogging" and can enable it at runtime without a relaunch.
///
/// The env flag is read once (it cannot change during the process); the UserDefaults flag is read
/// live on every access so the Settings toggle takes effect immediately.
enum VXProbe {
    /// The env flag is fixed for the process, so cache it; a false read still lets the live
    /// UserDefaults check below flip things on at runtime.
    private static let envEnabled: Bool = ProcessInfo.processInfo.environment["VORTX_PROBE"] == "1"

    /// UserDefaults key the Settings "Diagnostic logging" toggle binds to.
    static let defaultsKey = "stremiox.probeLogging"

    /// True when EITHER the launch env flag is set OR the Settings toggle is on right now. Computed so
    /// the runtime toggle is honored without a relaunch.
    static var enabled: Bool {
        envEnabled || UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Log one line under a category, but only when probing is enabled. The message is an autoclosure
    /// so callers pay nothing (no string building) when disabled. In addition to NSLog, the line is
    /// mirrored to a rolling on-disk file so the owner can export the full log later (Apple TV has no
    /// share sheet, so the export path grabs this file over the LAN).
    static func log(_ category: StaticString, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        // Build the line on the caller (cheap), then hand BOTH NSLog and the disk write to a background
        // serial queue so the caller thread (often main, or a player/engine callback) never blocks. This
        // is what keeps diagnostic logging ON without stalling the render thread.
        VXProbeFileLog.shared.record(category: String(describing: category), message: message())
    }

    /// Like `log`, but also records the line as the "last event" on the shared state so the next
    /// heartbeat echoes it. Use for discrete moments (a screen change, a source pick, a playback edge).
    static func event(_ category: StaticString, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        VXProbeFileLog.shared.record(category: String(describing: category), message: text)
        VXProbeState.shared.note("\(category): \(text)")   // tiny lock on a scratchpad, stays synchronous
    }

    /// On-disk URL of the rolling diagnostic log, exposed so the export helper can serve it.
    static var logFileURL: URL { VXProbeFileLog.shared.fileURL }

    /// Empty the rolling diagnostic log (used by a "clear" action or before a fresh capture).
    static func clearLog() { VXProbeFileLog.shared.clear() }

    /// Current process resident memory in MB via mach_task_basic_info, or nil if the kernel call fails.
    /// Exposed so callers outside the heartbeat (e.g. the F5 post-remux-teardown server-config replay) can log
    /// the process footprint around a suspected leak edge. Not gated on `enabled`: a caller that already
    /// decided to log wants a real number.
    static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }
}

/// Rolling on-disk mirror of the probe log. Every enabled `log`/`event` line is written here (with a
/// timestamp) so the owner can grab the whole session later. ALL work runs async on a dedicated serial
/// background queue, so callers (the main/render thread, player callbacks, the engine worker) never block
/// on disk I/O or NSLog. A persistent file handle is kept open so each line is a single write() syscall
/// instead of open+seek+close, and the front is trimmed only occasionally (once the file passes maxBytes)
/// rather than on every line. The serial queue is the synchronization, so no separate lock is needed.
final class VXProbeFileLog {
    static let shared = VXProbeFileLog()

    /// Trim once the file passes this size, keeping roughly the last `keepBytes`. ~3 MiB cap, ~2 MiB
    /// retained, so the tail the owner actually needs survives without the file growing without bound.
    private static let maxBytes = 3 * 1024 * 1024
    private static let keepBytes = 2 * 1024 * 1024

    /// Dedicated serial queue: serializes every write AND keeps all logging off the caller's thread.
    /// Utility QoS so it never contends with the main/render thread.
    private let queue = DispatchQueue(label: "stremiox.vxprobe.filelog", qos: .utility)

    /// caches/vortx-diag.log in the app container. Computed once; the caches dir always exists.
    let fileURL: URL

    /// Persistent write handle, opened lazily on the queue and reused. Queue-only; never touched off `queue`.
    private var handle: FileHandle?
    private var bytesWritten = 0

    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = caches.appendingPathComponent("vortx-diag.log")
    }

    /// Record one line: NSLog + file append, both dispatched ASYNC to the serial queue so the caller
    /// returns immediately. The timestamp is captured on the caller so it stays accurate even if the queue
    /// is momentarily backed up. Fail-soft: any file error is swallowed so logging never destabilizes the app.
    func record(category: String, message: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            // FORM THE WHOLE LINE THROUGH THE SHARED FORMATTER, then use those same bytes for both sinks, so
            // there is exactly ONE place where a probe line becomes durable and it is downstream of the
            // scrubber. NSLog gets the identical text (a device console log is shared just as casually as the
            // file). Category is scrubbed too, and the cap covers the COMPLETE line rather than the message
            // alone, so nothing can be appended after the cap to exceed it.
            //
            // This is a BACKSTOP, not the fix: the producers that build identifier-bearing strings are
            // corrected at their own call sites. It is here because the producer set is open, and a new one
            // must not be able to reintroduce the class. See VXProbeRedaction for what it does and, more
            // importantly, what it cannot do.
            let line = VXProbeRedaction.durableLine(timestamp: self.formatter.string(from: now),
                                                    category: category, message: message)
            NSLog("%@", String(line.dropLast()))
            guard let data = line.data(using: .utf8) else { return }
            self.write(data)
        }
    }

    /// Back-compat alias for existing call sites; enqueues exactly like `record`.
    func append(category: String, message: String) { record(category: category, message: message) }

    /// Write one line via the persistent handle, opening/creating it on first use, then trim the front only
    /// if the file has passed the cap. Queue-only.
    private func write(_ data: Data) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            if let h = handle { bytesWritten = Int((try? h.seekToEnd()) ?? 0) }
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            // The persistent handle went bad (file removed out from under us, disk pressure). Drop it so the
            // NEXT line reopens a fresh handle instead of reusing the dead one and silently losing every probe
            // line for the rest of the session.
            try? handle.close()
            self.handle = nil
            return
        }
        if bytesWritten > Self.maxBytes { trimFront() }
    }

    /// Rewrite the file keeping ~the last `keepBytes`, rounded up to a clean line. Runs rarely (only once
    /// the file passes the cap) and only on the queue, so the whole-file rewrite never touches a hot thread.
    private func trimFront() {
        try? handle?.close()
        handle = nil
        guard let data = try? Data(contentsOf: fileURL) else { bytesWritten = 0; return }
        let dropCount = data.count - Self.keepBytes
        guard dropCount > 0, dropCount < data.count else {
            // Reopen and continue appending if the drop math does not apply.
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
            return
        }
        var tail = data.subdata(in: dropCount..<data.count)
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail.subdata(in: (newline + 1)..<tail.count)
        }
        try? tail.write(to: fileURL, options: .atomic)
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        bytesWritten = tail.count
    }

    /// Empty the log file. Enqueued on the queue so it serializes with writes.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.handle?.close()
            self.handle = nil
            try? Data().write(to: self.fileURL, options: .atomic)
            self.bytesWritten = 0
        }
    }
}

/// Thread-safe scratchpad describing what the app is doing right now, sampled by the heartbeat. Held
/// behind a single lock; setters take it only briefly. Written from wherever the relevant state
/// changes (screen router, player) and read once a second by the heartbeat.
final class VXProbeState {
    static let shared = VXProbeState()
    private init() {}

    private let lock = NSLock()

    // All guarded by `lock`.
    private var route = "-"
    private var playerState = "idle"
    private var posSec = 0
    private var durSec = 0
    private var sourceLabel = "-"
    private var engine = "-"
    private var buffering = false
    private var lastEvent = "-"
    private var eventSeq = 0

    /// Current screen / route the user is on.
    func setRoute(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        route = s
    }

    /// Update any subset of the player fields. Nil arguments leave the existing value untouched, so a
    /// caller that only knows the position can pass just `pos:` without clobbering the rest.
    func setPlayer(state: String? = nil, pos: Int? = nil, dur: Int? = nil,
                   source: String? = nil, engine: String? = nil, buffering: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let state { playerState = state }
        if let pos { posSec = pos }
        if let dur { durSec = dur }
        if let source { sourceLabel = source }
        if let engine { self.engine = engine }
        if let buffering { self.buffering = buffering }
    }

    /// Record the most recent discrete event and bump the monotonically increasing sequence.
    func note(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lastEvent = s
        eventSeq += 1
    }

    /// Compact one-line summary for the heartbeat.
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return "screen=\(route) player=\(playerState) pos=\(posSec)/\(durSec)s src=\(sourceLabel) engine=\(engine) buf=\(buffering ? 1 : 0) last=\(lastEvent)"
    }
}

/// Once-a-second heartbeat: while probing is enabled it logs process uptime, current resident memory,
/// and `VXProbeState.snapshot()`. Runs on a dedicated utility queue so it never touches the main
/// thread. Idempotent to start; keeps a strong reference to the timer so it is not deallocated.
enum VXProbeHeartbeat {
    private static let queue = DispatchQueue(label: "stremiox.vxprobe.heartbeat", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static let start0 = ProcessInfo.processInfo.systemUptime

    /// Begin the heartbeat. No-op if already running or if probing is disabled.
    static func start() {
        guard VXProbe.enabled else { return }
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1.0, repeating: 1.0)
            t.setEventHandler { tick() }
            timer = t
            t.resume()
        }
    }

    private static func tick() {
        let uptime = Int(ProcessInfo.processInfo.systemUptime - start0)
        let mem = VXProbe.residentMemoryMB()
        let memText = mem.map { String(format: "%.0f", $0) } ?? "?"
        // Stamp the embedded streaming server's state (running / exited rc=N / stalled-loop age) into every
        // heartbeat so a device log shows exactly when the node server died or froze relative to memory and
        // player state. ServerDiagnostics is nil on builds with no server (the Lite tvOS app), in which case
        // the server field is omitted.
        let serverText = ServerDiagnostics.status().map { " server=[\($0)]" } ?? ""
        VXProbe.log("heartbeat", "up=\(uptime)s mem=\(memText)MB \(VXProbeState.shared.snapshot())\(serverText)")
    }
}
