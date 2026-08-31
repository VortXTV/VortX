import Foundation

/// Mirrors important log lines into Caches/diagnostics.log so they can be
/// pulled off a real device over the pairing tunnel (devicectl) without Console
/// access. The unified log is unreachable from a network-only Apple TV via CLI,
/// which made remote debugging of device-only bugs (the HDR display switch)
/// effectively impossible; this file is the escape hatch.
enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "stremiox.diaglog", qos: .utility)
    private static let byteLimit: UInt64 = 512 * 1024

    // Caches, not Documents: the tvOS sandbox DENIES writes to Documents on real
    // hardware (seen live: "deny(1) file-write-create .../Documents/diagnostics.log").
    // The simulator allows it, which is how this shipped wrong once. Caches is the
    // only sanctioned writable persistent-ish location on tvOS.
    private static let fileURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diagnostics.log")

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Synchronous append: returns only after the line is on disk. Use for crash
    /// breadcrumbs around suspect statements, where an async write would still be
    /// sitting in the queue when the process dies.
    static func logSync(_ category: String, _ message: String) {
        queue.sync { append(durableLine(category, message)) }
        mirrorToProbe(category, message)
    }

    /// Append one line. Safe from any thread; never throws, never blocks the caller.
    static func log(_ category: String, _ message: String) {
        let line = durableLine(category, message)
        queue.async { append(line) }
        mirrorToProbe(category, message)
    }

    /// Flush every queued durable write and return a coherent point-in-time image for a user-requested
    /// diagnostic export. Export runs away from the playback/render path, so this synchronous queue barrier
    /// cannot stall playback, while an export opened immediately after an event includes that event rather
    /// than an arbitrarily older on-disk prefix. Unlike `VXProbe.logSnapshot()`, this snapshot is never
    /// consumed: the always-on breadcrumb remains available for device-pairing retrieval and later exports.
    static func snapshot() -> DiagnosticsLogSnapshot {
        queue.sync {
            let bytes = (try? Data(contentsOf: fileURL)) ?? Data()
            return DiagnosticsLogSnapshot(contents: String(decoding: bytes, as: UTF8.self))
        }
    }

    /// This channel is ALWAYS ON. Unlike `VXProbe` there is no launch flag and no Settings toggle in front
    /// of it: `log`/`logSync` append for every user of every build, ~512 KiB durable in Caches, from 409
    /// important call sites carrying library ids, catalog ids, video ids, stream names, URL
    /// components, imported list titles and localized errors. Only the `mirrorToProbe` hop below is gated.
    ///
    /// So BOTH fields go through the shared bounded formatter before this file's own disk append, rather
    /// than only the ones that happen to be mirrored into the probe log. `category` is included because it
    /// is a free-form `String` from those same 152 call sites: an unguarded parameter means there is no
    /// chokepoint, and this is the chokepoint. The formatter also caps the COMPLETE line (timestamp,
    /// brackets, category, spacing and newline included) and neutralises control characters, so a message
    /// containing a newline can no longer forge a second entry with an attacker-chosen timestamp.
    private static func durableLine(_ category: String, _ message: String) -> String {
        VXProbeRedaction.durableLine(timestamp: stamp.string(from: Date()), category: category, message: message)
    }

    /// Mirror into the EXPORTABLE probe log (Caches/vortx-diag.log) when the owner has opted in. The normal
    /// in-app export also includes a bounded, clearly labelled, non-consuming tail of this always-on file,
    /// so a probe-off customer export is still actionable. Gated on VXProbe.enabled so probe-off playback
    /// pays nothing; VXProbeFileLog.record is async on its own utility queue and never calls back into
    /// DiagnosticsLog, so there is no recursion.
    private static func mirrorToProbe(_ category: String, _ message: String) {
        guard VXProbe.enabled else { return }
        VXProbeFileLog.shared.record(category: category, message: message)
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > byteLimit {
            // Dumb rotation: start over rather than juggling partial truncation.
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: data)
    }
}

/// The always-on log has no delivery acknowledgement or consume lifecycle. It is intentionally a contents-
/// only snapshot, keeping that distinction explicit at the type boundary from `VXProbeLogSnapshot`.
struct DiagnosticsLogSnapshot: Sendable {
    let contents: String
}
