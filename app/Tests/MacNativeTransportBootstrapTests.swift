import Foundation

enum PlaybackSettings { static let torrentsDisabled = false }
enum DiagnosticsLog {
    static let missingBinary = DispatchSemaphore(value: 0)
    static let releaseLifecycle = DispatchSemaphore(value: 0)
    static func log(_ category: String, _ message: String) {
        if message == "native streaming selected but server binary is missing" {
            missingBinary.signal()
            // Hold the real lifecycle queue so the endpoint read proves it never waits on reaping.
            _ = releaseLifecycle.wait(timeout: .now() + 5)
        }
    }
}
enum ServerDiagnostics {
    static func register(status: @escaping () -> String, logTail: @escaping (Int) -> [String]) {}
}

@main enum MacNativeTransportBootstrapTests {
    static func main() {
        // This executable deliberately contains no native server binary. Exercising the actual
        // lifecycle entry points must return before spawning tools or reclaiming ports.
        precondition(Bundle.main.path(forResource: "vortx-streaming-server", ofType: nil) == nil)
        NodeServer.startIfNeeded()
        precondition(DiagnosticsLog.missingBinary.wait(timeout: .now() + 5) == .success)
        let before = DispatchTime.now().uptimeNanoseconds
        precondition(NodeServer.nativeBaseURL == nil)
        precondition(DispatchTime.now().uptimeNanoseconds - before < 1_000_000_000,
                     "Endpoint read waited for the lifecycle queue")
        DiagnosticsLog.releaseLifecycle.signal()
        precondition(!NodeServer.started)
        precondition(NodeServer.statusDescription == "Native streaming server is missing from this build.")
        NodeServer.restart()
        precondition(DiagnosticsLog.missingBinary.wait(timeout: .now() + 5) == .success)
        precondition(NodeServer.nativeBaseURL == nil)
        DiagnosticsLog.releaseLifecycle.signal()
        precondition(!NodeServer.started)
        precondition(NodeServer.statusDescription == "Native streaming server is missing from this build.")
        print("PASS actual Mac bootstrap: native-only startup and restart fail closed without a binary; endpoint reads never join the lifecycle queue")
    }
}
