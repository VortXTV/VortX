import Foundation

/// Mirrors important log lines into Documents/diagnostics.log so they can be
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
        return formatter
    }()

    /// Synchronous append: returns only after the line is on disk. Use for crash
    /// breadcrumbs around suspect statements, where an async write would still be
    /// sitting in the queue when the process dies.
    static func logSync(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\n"
        queue.sync { append(line) }
    }

    /// Append one line. Safe from any thread; never throws, never blocks the caller.
    static func log(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\n"
        queue.async { append(line) }
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
