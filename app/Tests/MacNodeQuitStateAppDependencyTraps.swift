// Standalone identity-only quit-state fixture support; never include this file in an app target.
// These non-lifecycle app interfaces exist only to link the complete production Mac source.
// Every body traps and must remain unreachable. This supplies no fake app/dependency behavior.
// Foundation/Darwin/os and every production lifecycle declaration remain actual definitions.
#if os(macOS)
import Foundation

enum PlaybackSettings {
    static var torrentsDisabled: Bool { fatalError("out-of-scope PlaybackSettings access") }
}

enum NativeTransportPolicy {
    static var isRequired: Bool { fatalError("out-of-scope NativeTransportPolicy access") }
    static func selectsNative(required: Bool, preference: Bool) -> Bool {
        fatalError("out-of-scope NativeTransportPolicy selection")
    }
    static func boundNativePort(processRunning: Bool, receipt: String?) -> Int? {
        fatalError("out-of-scope native endpoint observation")
    }
}

enum ServerDiagnostics {
    static func register(status: @escaping @Sendable () -> String,
                         logTail: @escaping @Sendable (Int) -> [String]) {
        fatalError("out-of-scope diagnostics registration")
    }
}

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {
        fatalError("out-of-scope application logging")
    }
}
#endif
