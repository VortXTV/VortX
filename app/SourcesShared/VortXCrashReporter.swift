import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

/// In-app crash reporting for sideloaded builds.
///
/// Fatal capture is a process-lifetime C-owned boundary: fixed buffers, a pre-opened fd, a lock-free
/// terminal-write claim, raw writes, and the existing warmed best-effort backtrace/symbolizer. No Swift,
/// ARC, Foundation, application lock, or heap allocation is introduced by our signal-handler code.
/// Darwin does NOT promise backtrace()/backtrace_symbols_fd() are POSIX async-signal-safe; warming them
/// mitigates first-use loading but is not a safety guarantee. The next launch folds the marker with full
/// Foundation. The C handler restores the prior action and re-raises so the OS/other reporter can run.
///
/// Capture always runs. Folding respects VXProbe.enabled: diagnostics-off preserves the old marker and
/// the new process appends rather than truncating it. Marker shape/privacy and diagnostic sink are unchanged.
enum VortXCrashReporter {
    @MainActor private static var installed = false

    // Ordinary launch/fold state only. Neither C callback reads this lock or calls back into Swift.
    private static let launchHadPendingCrashMarker = OSAllocatedUnfairLock(initialState: false)

    /// Call as early as possible from each SwiftUI App's MainActor initializer. Idempotent. The app owns
    /// the process-wide handler-registration window; concurrent third-party registration needs coordination.
    @MainActor static func install() {
        guard !installed else { return }
        installed = true

        let marker = markerURL
        // Snapshot the PRIOR process before fold/open(O_CREAT) can change evidence. The signal path never
        // touches this normal-context lock; TerminationReceipt may synchronously read the checked snapshot.
        let pending = hasNonemptyCrashMarker(at: marker)
        launchHadPendingCrashMarker.withLock { $0 = pending }
        let preserveExisting = foldPreviousCrash(marker)

        // The fd is intentionally process-lifetime and O_CLOEXEC. No close/reuse can upgrade a stale
        // signal/exception attachment to a different resource. Preserve an unfolded prior marker verbatim.
        var markerFD: Int32 = -1
        marker.withUnsafeFileSystemRepresentation { rep in
            guard let rep else { return }
            let base = O_WRONLY | O_CREAT | O_CLOEXEC
            let flags = preserveExisting ? (base | O_APPEND) : (base | O_TRUNC)
            markerFD = open(rep, flags, mode_t(0o644))
        }
        _ = vortx_crash_signal_install(markerFD)

        // Force the immutable original C function pointer to initialize normally BEFORE registering ours.
        // The exception callback cannot initialize it lazily while handling the exception or capture itself.
        _ = previousExceptionHandler
        NSSetUncaughtExceptionHandler(vortxExceptionHandler)

        DiagnosticsLog.log("crash", "reporter installed (foldedPrevious=\(!preserveExisting && markerFD >= 0 ? "maybe" : "no"), fd=\(markerFD))")
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

    /// Whether `marker` contains evidence written by a prior fatal handler. Kept as a small pure file
    /// boundary so launch classification can be tested without installing process-wide signal handlers.
    static func hasNonemptyCrashMarker(at marker: URL) -> Bool {
        guard let data = try? Data(contentsOf: marker) else { return false }
        return !data.isEmpty
    }

    /// Immutable-in-meaning prior-process evidence, not a live marker-existence query. This lock is used
    /// only by ordinary Swift code; the signal handler owns separate fixed C storage.
    static var pendingCrashMarkerExists: Bool {
        launchHadPendingCrashMarker.withLock { $0 }
    }
}

// An immutable C function pointer, initialized explicitly during ordinary install before ours is registered.
// NSException itself stays on its original callback stack and is never transferred to an actor/queue.
private let previousExceptionHandler: (@convention(c) (NSException) -> Void)? = NSGetUncaughtExceptionHandler()

/// An uncaught Objective-C exception callback is not a signal context. Preserve the original richer
/// Foundation record and prior-handler chain. Its write claim is the same lock-free C claim consumed by a
/// fatal signal, so a following abort cannot append a duplicate record or race on Swift mutable globals.
private func vortxExceptionHandler(_ exception: NSException) {
    let fd = vortx_crash_signal_claim_marker()
    if fd >= 0 {
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
    previousExceptionHandler?(exception)
}
