// Standalone executable for the always-on diagnostics snapshot barrier:
//
//   xcrun swiftc -warnings-as-errors -o /tmp/diagnostics-log-export-test \
//     app/SourcesShared/VXProbeRedaction.swift \
//     app/SourcesShared/DiagnosticsLog.swift \
//     app/Tests/DiagnosticsLogExportTests.swift && /tmp/diagnostics-log-export-test
//
// `DiagnosticsLog.log` intentionally returns before its disk write. The export snapshot is allowed to wait
// on that serial queue because callers invoke it only from a user-requested export path, never playback.

import Foundation

// The snapshot contract is independent of the opt-in mirror. These minimal compile-time stand-ins keep this
// focused executable off VXProbe's unrelated heartbeat/server dependencies while exercising the production
// DiagnosticsLog queue and file path unchanged.
enum VXProbe {
    static var enabled: Bool { false }
}

final class VXProbeFileLog {
    static let shared = VXProbeFileLog()
    func record(category: String, message: String) {}
}

@main
struct DiagnosticsLogExportTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ what: String) {
            if condition {
                print("PASS  \(what)")
            } else {
                failures += 1
                print("FAIL  \(what)")
            }
        }

        let marker = "diagnostics-export-barrier-\(UUID().uuidString.lowercased())"
        DiagnosticsLog.log("diagnostics-export-test", marker)
        let snapshot = DiagnosticsLog.snapshot()
        expect(snapshot.contents.contains(marker),
               "the snapshot barrier includes a queued always-on write")

        let secondSnapshot = DiagnosticsLog.snapshot()
        expect(secondSnapshot.contents.contains(marker),
               "snapshotting does not consume the always-on diagnostics log")

        exit(failures == 0 ? 0 : 1)
    }
}
