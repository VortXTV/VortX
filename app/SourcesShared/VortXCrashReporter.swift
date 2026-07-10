import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// In-app crash reporting for sideloaded builds.
///
/// A sideloaded Apple TV has no reachable way to hand its `.ips` crash reports to the owner (no Console,
/// no share sheet, no easy devicectl pull), so a crash was previously invisible: the app just vanished
/// with nothing in the exportable diagnostics log. This installs process-wide handlers so a crash writes
/// its OWN report into the app container, and the NEXT launch folds that report into the same rolling
/// diagnostic log the owner already exports over LAN/QR (Apple TV, iPhone) or into Downloads (Mac).
///
/// The split is deliberate and is the standard safe pattern:
///  - **At crash time** we do the absolute minimum, using ONLY async-signal-safe calls: a pre-opened
///    file descriptor + raw `write()` + `backtrace_symbols_fd()`. No Foundation, no Swift `String`
///    interpolation, no `malloc`. Those are not async-signal-safe and can deadlock or corrupt a dying
///    process. Every buffer the handler touches is allocated ONCE at `install()` time on the main thread.
///  - **On the next launch** (`install()`, called first thing from each app's `@main`) we read the small
///    crash marker with full Foundation, fold it into the exportable log, and delete it so it reports once.
///
/// After writing the marker the handler chains to the previously-installed handler / re-raises the signal,
/// so the OS still records its own crash report and any other installed reporter still runs.
///
/// Gating: the marker CAPTURE always runs (it is tiny and costs nothing until a crash), but folding the
/// captured report into the exportable log respects `VXProbe.enabled`, the same "Diagnostic logging"
/// toggle the rest of VXProbe honors. When diagnostics is off at launch, the marker is preserved (not
/// folded, not deleted) so a later launch with diagnostics on can still report the crash.
enum VortXCrashReporter {

    /// Install the handlers and fold any crash from the previous run. Call as early as possible from each
    /// app's `@main` init, before the first view. Idempotent: safe to call more than once.
    static func install() {
        guard !gInstalled else { return }
        gInstalled = true

        let marker = markerURL

        // 1) Report the previous run's crash (if any). Returns true when a crash marker was left in place
        //    (diagnostics was off), so the fresh handler must APPEND rather than truncate and clobber it.
        let preserveExisting = foldPreviousCrash(marker)

        // 2) Allocate every buffer the signal handler will use NOW, on the main thread. Allocation is not
        //    async-signal-safe, so nothing in the handler may allocate; it only reads these globals.
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(gFramesCapacity))
        frames.initialize(repeating: nil, count: Int(gFramesCapacity))
        gFrames = frames

        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: gScratchCapacity)
        scratch.initialize(repeating: 0, count: gScratchCapacity)
        gScratch = scratch

        let prev = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(gMaxSignal))
        prev.initialize(repeating: sigaction(), count: Int(gMaxSignal))
        gPrevActions = prev

        // 3) Warm up backtrace(): its first call can lazily load/allocate inside dyld. Do that here so the
        //    handler's call only walks the stack. backtrace_symbols_fd (unlike backtrace_symbols) writes
        //    straight to the fd without malloc, so it is safe to call from the handler.
        _ = backtrace(frames, gFramesCapacity)

        // 4) Pre-open the marker fd. O_CLOEXEC so it is never inherited by the Mac node child process.
        //    APPEND when preserving an unfolded crash from a diagnostics-off run; TRUNC for a clean slate.
        marker.withUnsafeFileSystemRepresentation { rep in
            guard let rep else { return }
            let base = O_WRONLY | O_CREAT | O_CLOEXEC
            let flags = preserveExisting ? (base | O_APPEND) : (base | O_TRUNC)
            gMarkerFD = open(rep, flags, mode_t(0o644))
        }

        // 5) Ignore SIGPIPE: a write to a socket the peer closed (network, the embedded server) should
        //    never kill the app. This is the conventional server-side default.
        signal(SIGPIPE, SIG_IGN)

        // 6) Install a handler for each fatal signal, saving the prior action so the handler can chain to
        //    it (another crash reporter, or the OS default that produces the .ips report).
        var action = sigaction()
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        action.__sigaction_u = __sigaction_u(__sa_handler: vortxSignalHandler)
        for sig in gFatalSignals where sig >= 0 && sig < gMaxSignal {
            _ = sigaction(sig, &action, prev + Int(sig))
        }

        // 7) Uncaught Obj-C / Swift exception handler. This is NOT a signal context (the runtime calls us
        //    normally, just before it aborts), so Foundation is usable there. Save any handler already in
        //    place so ours can chain to it (another reporter, or the runtime default) after writing the marker.
        gPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(vortxExceptionHandler)

        DiagnosticsLog.log("crash", "reporter installed (foldedPrevious=\(!preserveExisting && gMarkerFD >= 0 ? "maybe" : "no"), fd=\(gMarkerFD))")
    }

    // MARK: - Next-launch fold (full Foundation; runs on the main thread at launch)

    /// Fold a marker left by a previous crash into the exportable diagnostic log, then delete it so it is
    /// reported once. Returns true when the marker was intentionally LEFT in place (diagnostics off), so the
    /// caller opens the fresh fd in append mode instead of truncating an unreported crash.
    private static func foldPreviousCrash(_ marker: URL) -> Bool {
        guard let data = try? Data(contentsOf: marker), !data.isEmpty,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return false   // nothing pending (missing, empty, or the last run exited cleanly)
        }

        // Respect the diagnostics toggle for the FOLD only. Capture already happened; keep the marker so a
        // later diagnostics-on launch can still report this crash.
        guard VXProbe.enabled else { return true }

        // Marker shape written by the handlers:
        //   line 1: "<LABEL> <epochSeconds>"   (LABEL = signal name like SIGSEGV, or "EXCEPTION:<name>")
        //   rest  : reason (exceptions only) + symbolized backtrace
        let newline = text.firstIndex(of: "\n")
        let header = newline.map { String(text[text.startIndex..<$0]) } ?? text
        let body = newline.map { String(text[text.index(after: $0)...]) } ?? ""
        let parts = header.split(separator: " ", maxSplits: 1)
        let label = parts.first.map(String.init) ?? "unknown"
        let when = (parts.count > 1 ? TimeInterval(parts[1]) : nil).map(readableTimestamp) ?? "unknown time"

        // Tag as "[crash] <signal> at <ts>\n<backtrace>" via the shared exportable sink (Caches/vortx-diag.log).
        VXProbeFileLog.shared.record(category: "crash", message: "\(label) at \(when)\n\(body)")

        try? FileManager.default.removeItem(at: marker)
        return false
    }

    /// Human-readable rendering of a crash's capture time (recorded as epoch seconds by the handler).
    private static func readableTimestamp(_ epoch: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// `Caches/vortx-lastcrash.txt`, the same container directory VXProbe's exportable log lives in.
    private static var markerURL: URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("vortx-lastcrash.txt")
    }
}

// MARK: - Process-wide state (allocated once in install(); the handler only READS these)

/// Fatal signals we capture. SIGPIPE is handled separately (ignored, not captured).
private let gFatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGTRAP]

/// Upper bound for the per-signal saved-action table; every signal above is far below this.
private let gMaxSignal: Int32 = 32

/// Pre-opened write fd for the crash marker. -1 until install() opens it.
private var gMarkerFD: Int32 = -1

/// Pre-allocated backtrace frame buffer and its capacity (frames, not bytes).
private var gFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private let gFramesCapacity: Int32 = 128

/// Pre-allocated scratch used only to render the epoch integer to ASCII without allocating.
private var gScratch: UnsafeMutablePointer<UInt8>?
private let gScratchCapacity = 32

/// Saved previous sigaction per signal number, so the handler can chain to it.
private var gPrevActions: UnsafeMutablePointer<sigaction>?

/// Uncaught-exception handler installed before ours (another reporter, or the runtime default), saved at
/// install() so our exception handler can chain to it after writing the marker.
private var gPreviousExceptionHandler: (@convention(c) (NSException) -> Void)?

/// Best-effort single-writer guard for the terminal path: set once a marker has been written so an
/// exception that then aborts (SIGABRT) does not double-write, and a re-entrant fault is ignored.
private var gAlreadyWrote: sig_atomic_t = 0

private var gInstalled = false

// MARK: - Async-signal-safe write primitives
// Everything below is callable from a signal handler: no allocation, no Foundation, no Swift String,
// only raw memory reads and write()/fsync() syscalls.

/// Write exactly `count` bytes from `ptr`, looping over partial writes. Best-effort: on any error/EOF in
/// this terminal path we stop rather than spin.
private func asyncSafeWrite(_ fd: Int32, _ ptr: UnsafePointer<UInt8>, _ count: Int) {
    var remaining = count
    var cursor = ptr
    while remaining > 0 {
        let written = write(fd, cursor, remaining)
        if written <= 0 { break }
        remaining -= written
        cursor += written
    }
}

/// Write a compile-time-constant string. StaticString is backed by static data in the binary, so
/// `withUTF8Buffer` yields a pointer into that data with no heap allocation.
private func asyncSafeWrite(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { buffer in
        if let base = buffer.baseAddress, buffer.count > 0 {
            asyncSafeWrite(fd, base, buffer.count)
        }
    }
}

/// Write a single byte via a stack local (no heap).
private func asyncSafeWriteByte(_ fd: Int32, _ byte: UInt8) {
    var b = byte
    _ = withUnsafePointer(to: &b) { write(fd, $0, 1) }
}

/// Render a non-negative integer to decimal ASCII in the pre-allocated scratch buffer and write it.
private func asyncSafeWriteInt(_ fd: Int32, _ value: Int) {
    guard let scratch = gScratch else { return }
    var v = value > 0 ? value : 0
    var i = gScratchCapacity
    if v == 0 {
        i -= 1
        scratch[i] = 0x30 // '0'
    } else {
        while v > 0 && i > 0 {
            i -= 1
            scratch[i] = UInt8(0x30 + (v % 10))
            v /= 10
        }
    }
    asyncSafeWrite(fd, scratch + i, gScratchCapacity - i)
}

/// Constant name for a signal, as static string data (no allocation).
private func signalName(_ sig: Int32) -> StaticString {
    switch sig {
    case SIGABRT: return "SIGABRT"
    case SIGSEGV: return "SIGSEGV"
    case SIGILL:  return "SIGILL"
    case SIGBUS:  return "SIGBUS"
    case SIGFPE:  return "SIGFPE"
    case SIGTRAP: return "SIGTRAP"
    default:      return "SIGNAL"
    }
}

// MARK: - Handlers

/// Fatal-signal handler. Runs on the faulting thread with the process in an undefined state, so it uses
/// ONLY async-signal-safe operations, then restores the previous handler and re-raises so the OS still
/// records its own crash report.
private func vortxSignalHandler(_ sig: Int32) {
    let fd = gMarkerFD
    if gAlreadyWrote == 0 && fd >= 0 {
        gAlreadyWrote = 1
        // Header: "<SIGNAME> <epochSeconds>\n". time() is on the POSIX async-signal-safe list.
        asyncSafeWrite(fd, signalName(sig))
        asyncSafeWriteByte(fd, 0x20)              // space
        asyncSafeWriteInt(fd, Int(time(nil)))
        asyncSafeWriteByte(fd, 0x0A)              // newline
        if let frames = gFrames {
            let n = backtrace(frames, gFramesCapacity)
            backtrace_symbols_fd(frames, n, fd)   // symbolized frames straight to the fd, no malloc
        }
        asyncSafeWriteByte(fd, 0x0A)              // trailing newline
        fsync(fd)                                 // flush before we die so the marker survives
    }
    // Chain: restore the prior action (another handler, or the OS default) and re-deliver the signal.
    if let prev = gPrevActions, sig >= 0 && sig < gMaxSignal {
        sigaction(sig, prev + Int(sig), nil)
    } else {
        signal(sig, SIG_DFL)
    }
    raise(sig)
}

/// Uncaught Obj-C / Swift exception handler. Not a signal context: the runtime calls this normally just
/// before aborting, so Foundation is safe here. Writes a richer record (name + reason + symbolized stack)
/// to the same pre-opened marker fd, and marks the marker written so the ensuing abort()/SIGABRT does not
/// duplicate it (the signal handler still chains to the OS).
private func vortxExceptionHandler(_ exception: NSException) {
    let fd = gMarkerFD
    if fd >= 0, gAlreadyWrote == 0 {
        gAlreadyWrote = 1
        let name = exception.name.rawValue
        let reason = exception.reason ?? "(no reason)"
        let symbols = exception.callStackSymbols.joined(separator: "\n")
        let epoch = Int(Date().timeIntervalSince1970)
        let block = "EXCEPTION:\(name) \(epoch)\n\(reason)\n\(symbols)\n"
        if let data = block.data(using: .utf8) {
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    _ = write(fd, base, raw.count)
                }
            }
        }
        fsync(fd)
    }
    // Chain to the handler installed before us so its reporter still runs; the runtime then aborts, and the
    // ensuing SIGABRT is caught by the signal handler, which chains on to the OS default for the .ips report.
    gPreviousExceptionHandler?(exception)
}
