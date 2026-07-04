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
        let text = message()
        NSLog("[%@] %@", String(describing: category), text)
        VXProbeFileLog.shared.append(category: String(describing: category), message: text)
    }

    /// Like `log`, but also records the line as the "last event" on the shared state so the next
    /// heartbeat echoes it. Use for discrete moments (a screen change, a source pick, a playback edge).
    static func event(_ category: StaticString, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        NSLog("[%@] %@", String(describing: category), text)
        VXProbeFileLog.shared.append(category: String(describing: category), message: text)
        VXProbeState.shared.note("\(category): \(text)")
    }

    /// On-disk URL of the rolling diagnostic log, exposed so the export helper can serve it.
    static var logFileURL: URL { VXProbeFileLog.shared.fileURL }

    /// Empty the rolling diagnostic log (used by a "clear" action or before a fresh capture).
    static func clearLog() { VXProbeFileLog.shared.clear() }
}

/// Rolling on-disk mirror of the probe log. Every enabled `log`/`event` line is appended here (with a
/// timestamp) so the owner can grab the whole session later. Kept to a sane size: when the file grows
/// past `maxBytes` the front is truncated, keeping roughly the most recent `keepBytes`. Thread-safe
/// behind its own lock so appends from any queue (heartbeat, player, network callbacks) are serialized.
final class VXProbeFileLog {
    static let shared = VXProbeFileLog()

    /// Truncate once the file passes this size, keeping roughly the last `keepBytes`. ~3 MiB cap, ~2 MiB
    /// retained, so the tail the owner actually needs survives without the file growing without bound.
    private static let maxBytes = 3 * 1024 * 1024
    private static let keepBytes = 2 * 1024 * 1024

    private let lock = NSLock()

    /// caches/vortx-diag.log in the app container. Computed once; the caches dir always exists.
    let fileURL: URL

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

    /// Append one timestamped line, then truncate the front if the file has grown past the cap. Fail-soft:
    /// any file error is swallowed so diagnostic logging never destabilizes the app.
    func append(category: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File does not exist yet: create it with this first line.
            try? data.write(to: fileURL, options: .atomic)
        }

        truncateIfNeeded()
    }

    /// If the file is larger than `maxBytes`, rewrite it keeping only the last `keepBytes` (rounded up to
    /// the next newline so the retained head starts on a clean line). Called under `lock`.
    private func truncateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > Self.maxBytes else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }

        let dropCount = data.count - Self.keepBytes
        guard dropCount > 0, dropCount < data.count else { return }
        var tail = data.subdata(in: dropCount..<data.count)
        // Trim any partial leading line so the retained head begins on a clean boundary.
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail.subdata(in: (newline + 1)..<tail.count)
        }
        try? tail.write(to: fileURL, options: .atomic)
    }

    /// Empty the log file (truncate to zero). Fail-soft.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? Data().write(to: fileURL, options: .atomic)
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
        let mem = residentMemoryMB()
        let memText = mem.map { String(format: "%.0f", $0) } ?? "?"
        VXProbe.log("heartbeat", "up=\(uptime)s mem=\(memText)MB \(VXProbeState.shared.snapshot())")
    }

    /// Current resident memory in MB via mach_task_basic_info. Returns nil if the kernel call fails,
    /// so the heartbeat degrades to "mem=?MB" rather than logging a wrong number.
    private static func residentMemoryMB() -> Double? {
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
