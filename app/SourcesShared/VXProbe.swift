import Foundation
import os   // os_proc_available_memory (the jetsam-headroom reading in the heartbeat)

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

    /// Flush every queued writer and return one coherent export snapshot. Export runs off the playback path,
    /// so this bounded synchronous hop cannot stall rendering and it prevents a QR opened immediately after
    /// an event from reading an older on-disk prefix.
    static func logSnapshot() -> VXProbeLogSnapshot { VXProbeFileLog.shared.snapshot() }

    /// Consume only the bytes represented by a successfully delivered snapshot. Any lines appended while
    /// the phone downloaded that snapshot stay in the rolling log for the next export.
    static func consumeLogSnapshot(_ snapshot: VXProbeLogSnapshot) {
        VXProbeFileLog.shared.consume(snapshot)
    }

    /// Empty the rolling diagnostic log (used by a "clear" action or before a fresh capture).
    static func clearLog() { VXProbeFileLog.shared.clear() }

    /// Current process resident memory in MB via mach_task_basic_info, or nil if the kernel call fails.
    /// Exposed so callers outside the heartbeat (e.g. the F5 post-remux-teardown server-config replay) can log
    /// the process footprint around a suspected leak edge. Not gated on `enabled`: a caller that already
    /// decided to log wants a real number.
    ///
    /// A2-2: this is whole-process RSS (the app plus the in-process node server), so the heartbeat's `mem=`
    /// field covers both. The node heap alone rides the separate `server=[... heap=NMB]` field.
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

    /// Remaining memory this process may allocate before the OS kills it, in MB, or nil where the platform
    /// cannot answer. THIS is the number that predicts a jetsam kill; `residentMemoryMB()` alone does not.
    /// A resident figure has no meaning without the limit it is measured against, and that limit is not a
    /// constant: it varies by device model and by whether the app is foreground, so "800 MB resident" is
    /// alarming on one Apple TV and unremarkable on another. `os_proc_available_memory()` reports the
    /// headroom directly, so a log line can be read on its own without knowing the hardware.
    ///
    /// nil on macOS (the SDK marks the call `API_UNAVAILABLE(macos)`) and on a 0 answer, which is what the
    /// call returns when no app memory limit is in force.
    static func availableMemoryMB() -> Double? {
        #if os(macOS)
        return nil
        #else
        let bytes = os_proc_available_memory()
        guard bytes > 0 else { return nil }
        return Double(bytes) / (1024.0 * 1024.0)
        #endif
    }
}

struct VXProbeLogSnapshot: Sendable {
    let contents: String
    fileprivate let bytes: Data
}

/// Rolling on-disk mirror of the probe log. Every enabled `log`/`event` line is written here (with a
/// timestamp) so the owner can grab the whole session later. ALL work runs async on a dedicated serial
/// background queue, so callers (the main/render thread, player callbacks, the engine worker) never block
/// on disk I/O or NSLog. A persistent file handle is kept open so each line is a single write() syscall
/// instead of open+seek+close, and the front is trimmed only occasionally (once the file passes maxBytes)
/// rather than on every line. Every append/snapshot/consume operation is ordered on the dedicated serial
/// queue; the checked lock owns the mutable writer state for Swift concurrency as well.
final class VXProbeFileLog: Sendable {
    static let shared = VXProbeFileLog()

    private static let maxBytes = 3 * 1024 * 1024
    private static let keepBytes = 2 * 1024 * 1024
    private let queue = DispatchQueue(label: "stremiox.vxprobe.filelog", qos: .utility)
    let fileURL: URL

    private struct State {
        var handle: FileHandle?
        var bytesWritten = 0
        var formatter: DateFormatter?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = caches.appendingPathComponent("vortx-diag.log")
    }

    func record(category: String, message: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            self.state.withLock { state in
                // Use one scrubbed line for both sinks. The cap applies to the complete durable line,
                // including its timestamp and category, rather than only to the producer's message.
                let formatter: DateFormatter
                if let cached = state.formatter {
                    formatter = cached
                } else {
                    let created = DateFormatter()
                    created.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                    created.locale = Locale(identifier: "en_US_POSIX")
                    state.formatter = created
                    formatter = created
                }
                let line = VXProbeRedaction.durableLine(
                    timestamp: formatter.string(from: now),
                    category: category,
                    message: message
                )
                NSLog("%@", String(line.dropLast()))
                guard let data = line.data(using: .utf8) else { return }
                self.write(data, state: &state)
            }
        }
    }

    func append(category: String, message: String) { record(category: category, message: message) }

    private func write(_ data: Data, state: inout State) {
        if state.handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            state.handle = try? FileHandle(forWritingTo: fileURL)
            if let handle = state.handle { state.bytesWritten = Int((try? handle.seekToEnd()) ?? 0) }
        }
        guard let handle = state.handle else { return }
        do {
            try handle.write(contentsOf: data)
            state.bytesWritten += data.count
        } catch {
            try? handle.close()
            state.handle = nil
            return
        }
        if state.bytesWritten > Self.maxBytes { trimFront(state: &state) }
    }

    private func trimFront(state: inout State) {
        try? state.handle?.close()
        state.handle = nil
        guard let data = try? Data(contentsOf: fileURL) else { state.bytesWritten = 0; return }
        let dropCount = data.count - Self.keepBytes
        guard dropCount > 0, dropCount < data.count else {
            state.handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? state.handle?.seekToEnd()
            return
        }
        var tail = data.subdata(in: dropCount..<data.count)
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail.subdata(in: (newline + 1)..<tail.count)
        }
        try? tail.write(to: fileURL, options: .atomic)
        state.handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? state.handle?.seekToEnd()
        state.bytesWritten = tail.count
    }

    func snapshot() -> VXProbeLogSnapshot {
        // This export-only synchronous hop drains earlier writes and takes one coherent file image.
        queue.sync {
            state.withLock { state in
                try? state.handle?.synchronize()
                let bytes = (try? Data(contentsOf: fileURL)) ?? Data()
                return VXProbeLogSnapshot(contents: String(decoding: bytes, as: UTF8.self), bytes: bytes)
            }
        }
    }

    func consume(_ snapshot: VXProbeLogSnapshot) {
        queue.async { [weak self] in
            guard let self, !snapshot.bytes.isEmpty else { return }
            self.state.withLock { state in
                try? state.handle?.synchronize()
                try? state.handle?.close()
                state.handle = nil
                let current = (try? Data(contentsOf: self.fileURL)) ?? Data()
                // Consume only the exact delivered prefix. A mismatch means trimming/replacement occurred,
                // so preserve the entire current log rather than risk deleting newer history.
                guard let remaining = VXDiagExportPolicy.remainingLogAfterSuccessfulSnapshot(
                    snapshot: snapshot.bytes,
                    current: current
                ) else {
                    self.reopenForAppend(state: &state, byteCount: current.count)
                    return
                }
                do {
                    try remaining.write(to: self.fileURL, options: .atomic)
                    self.reopenForAppend(state: &state, byteCount: remaining.count)
                } catch {
                    self.reopenForAppend(state: &state, byteCount: current.count)
                }
            }
        }
    }

    private func reopenForAppend(state: inout State, byteCount: Int) {
        state.handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? state.handle?.seekToEnd()
        state.bytesWritten = byteCount
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.state.withLock { state in
                try? state.handle?.close()
                state.handle = nil
                try? Data().write(to: self.fileURL, options: .atomic)
                state.bytesWritten = 0
            }
        }
    }
}

/// Thread-safe scratchpad describing what the app is doing right now, sampled by the heartbeat. Held
/// behind a single lock; setters take it only briefly. Written from wherever the relevant state
/// changes (screen router, player) and read once a second by the heartbeat.
final class VXProbeState: Sendable {
    static let shared = VXProbeState()
    private init() {}

    private struct State {
        var route = "-"
        var playerState = "idle"
        var posSec = 0
        var durSec = 0
        var sourceLabel = "-"
        var engine = "-"
        var buffering = false
        var lastEvent = "-"
        var eventSeq = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func setRoute(_ value: String) {
        state.withLock { $0.route = value }
    }

    func setPlayer(state playerState: String? = nil, pos: Int? = nil, dur: Int? = nil,
                   source: String? = nil, engine: String? = nil, buffering: Bool? = nil) {
        state.withLock { state in
            if let playerState { state.playerState = playerState }
            if let pos { state.posSec = pos }
            if let dur { state.durSec = dur }
            if let source { state.sourceLabel = source }
            if let engine { state.engine = engine }
            if let buffering { state.buffering = buffering }
        }
    }

    func clearPlayer() {
        state.withLock { state in
            state.playerState = "idle"
            state.posSec = 0
            state.durSec = 0
            state.sourceLabel = "-"
            state.engine = "-"
            state.buffering = false
        }
    }

    func note(_ value: String) {
        state.withLock { state in
            state.lastEvent = value
            state.eventSeq += 1
        }
    }

    func snapshot() -> String {
        state.withLock { state in
            "screen=\(state.route) player=\(state.playerState) pos=\(state.posSec)/\(state.durSec)s src=\(state.sourceLabel) engine=\(state.engine) buf=\(state.buffering ? 1 : 0) last=\(state.lastEvent)"
        }
    }
}

/// Once-a-second heartbeat: while probing is enabled it logs process uptime, current resident memory,
/// and `VXProbeState.snapshot()`. Runs on a dedicated utility queue so it never touches the main
/// thread. Idempotent to start; keeps a strong reference to the timer so it is not deallocated.
enum VXProbeHeartbeat {
    private static let queue = DispatchQueue(label: "stremiox.vxprobe.heartbeat", qos: .utility)
    private static let timerState = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)
    private static let start0 = ProcessInfo.processInfo.systemUptime

    /// Begin the heartbeat. No-op if already running or if probing is disabled.
    static func start() {
        guard VXProbe.enabled else { return }
        queue.sync {
            guard timerState.withLock({ $0 == nil }) else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1.0, repeating: 1.0)
            t.setEventHandler { tick() }
            timerState.withLock { $0 = t }
            t.resume()
        }
    }

    private static func tick() {
        let uptime = Int(ProcessInfo.processInfo.systemUptime - start0)
        let mem = VXProbe.residentMemoryMB()
        let memText = mem.map { String(format: "%.0f", $0) } ?? "?"
        // Jetsam headroom, alongside (never instead of) resident size. A resident-only heartbeat cannot say
        // whether a spike was dangerous: FAIL-260804-10 spent the investigation arguing about how close an
        // RSS figure was to a kill, which is unanswerable without the per-device limit. `avail` answers it
        // directly. Absent (the field is omitted) on macOS and wherever no app memory limit is in force, so
        // the line never carries a fake zero that would read as "about to die".
        let availText = VXProbe.availableMemoryMB().map { String(format: " avail=%.0fMB", $0) } ?? ""
        // Stamp the embedded streaming server's state (running / exited rc=N / stalled-loop age) into every
        // heartbeat so a device log shows exactly when the node server died or froze relative to memory and
        // player state. ServerDiagnostics is nil on builds with no server (the Lite tvOS app), in which case
        // the server field is omitted.
        let serverText = ServerDiagnostics.status().map { " server=[\($0)]" } ?? ""
        VXProbe.log("heartbeat", "up=\(uptime)s mem=\(memText)MB\(availText) \(VXProbeState.shared.snapshot())\(serverText)")
    }
}
