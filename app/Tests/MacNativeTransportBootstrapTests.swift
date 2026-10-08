import Foundation

enum PlaybackSettings { static let torrentsDisabled = false }
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
enum ServerDiagnostics {
    static func register(status: @escaping () -> String, logTail: @escaping (Int) -> [String]) {}
}

@main enum MacNativeTransportBootstrapTests {
    static func main() {
        // This executable deliberately contains neither transport binary. Exercising the actual
        // lifecycle entry points must return before spawning tools, reclaiming ports or starting Node.
        precondition(NativeTransportPolicy.isRequired)
        precondition(NodeServer.nativeServerEnabled)
        NodeServer.startIfNeeded()
        precondition(NodeServer.nativeBaseURL == nil) // synchronizes with queued startup
        precondition(!NodeServer.started)
        precondition(NodeServer.statusDescription == "Native streaming server is missing from this build.")
        NodeServer.restart()
        precondition(NodeServer.nativeBaseURL == nil)
        precondition(!NodeServer.started)
        NodeServer.nativeServerEnabled = false
        precondition(NodeServer.nativeServerEnabled)
        print("PASS actual Mac bootstrap: required native fails closed without a binary and cannot downgrade")
    }
}
