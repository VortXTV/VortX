// Standalone-compilation stubs for the DV rendition/stall repro harness (same shape as the sibling
// harnesses in app/Tests). Only the exact members the compiled production files read are provided.

import Foundation

struct RemoteConfig {
    struct Snapshot {
        let dvRemuxWindowMiB: Int
        func isFeatureOn(_ name: String, default def: Bool) -> Bool {
            // The harness pins both Beta 7 rendition flags ON - the field configuration under test.
            if name == "dvRemuxMultiAudio" || name == "dvRemuxSubtitles" || name == "dvRemuxHLS" {
                return true
            }
            return def
        }
    }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

enum DiagnosticsLog {
    static let lock = NSLock()
    nonisolated(unsafe) static var lines: [String] = []
    static func log(_ tag: String, _ message: String) {
        let line = "[\(tag)] \(message)"
        lock.lock(); lines.append(line); lock.unlock()
        FileHandle.standardError.write(Data(("DIAG " + line + "\n").utf8))
    }
    static func capturedLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

enum VXProbe {
    static func log(_ tag: String, _ message: String) { DiagnosticsLog.log(tag, message) }
}

/// Production HDRDisplayMode is tvOS panel machinery; on iOS/macOS `isSwitchSettled` is constant true
/// (the server comment states the same), so the stub mirrors the non-tvOS production value.
enum HDRDisplayMode {
    static var isSwitchSettled: Bool { true }
}
