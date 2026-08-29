// Runtime regression for launch-time crash-marker classification.
//
// RUN:
//   xcrun swiftc -o /tmp/crash-marker-launch-snapshot-tests \
//     app/SourcesShared/TerminationReceiptPolicy.swift \
//     app/SourcesShared/VortXCrashReporter.swift \
//     app/Tests/CrashMarkerLaunchSnapshotTests.swift && \
//   /tmp/crash-marker-launch-snapshot-tests

import Foundation

// Minimal diagnostics seams needed to link the crash reporter without launching the app.
enum VXProbe { static var enabled = false }
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
final class VXProbeFileLog {
    static let shared = VXProbeFileLog()
    func record(category: String, message: String) {}
}

@main
enum CrashMarkerLaunchSnapshotTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-crash-marker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing.txt")
        let empty = root.appendingPathComponent("empty.txt")
        let captured = root.appendingPathComponent("captured.txt")
        try Data().write(to: empty)
        try Data("SIGABRT 123\nframe".utf8).write(to: captured)

        let receipt = TerminationReceiptPolicy.Receipt.initial(now: 100)
        let missingEvidence = VortXCrashReporter.hasNonemptyCrashMarker(at: missing)
        let emptyEvidence = VortXCrashReporter.hasNonemptyCrashMarker(at: empty)
        let capturedEvidence = VortXCrashReporter.hasNonemptyCrashMarker(at: captured)

        expect("missing prior marker is not crash evidence", !missingEvidence)
        expect("empty O_CREAT marker is not crash evidence", !emptyEvidence)
        expect("nonempty prior marker is crash evidence", capturedEvidence)
        expect("unclean receipt plus no nonempty marker is not classified crash",
               TerminationReceiptPolicy.classify(
                receipt: receipt, crashMarkerExists: emptyEvidence, now: 101) != .crash)
        expect("unclean receipt plus nonempty prior marker is classified crash",
               TerminationReceiptPolicy.classify(
                receipt: receipt, crashMarkerExists: capturedEvidence, now: 101) == .crash)

        print("CrashMarkerLaunchSnapshotTests: ALL PASS")
    }

    private static func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
        guard condition() else {
            fputs("FAIL  \(name)\n", stderr)
            exit(1)
        }
        print("PASS  \(name)")
    }
}
