import Foundation

/// Simulator-only launch-argument harness for exercising the same Network.framework listener used by the
/// product target. It does not fetch a remote origin and never logs a route token, URL, or request header.
enum CommunityGatewayProductProof {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-community-gateway-proof") else { return }
        Task {
            let gateway = CommunityStreamGateway.shared
            gateway.stop()
            do {
                try await gateway.start()
                let route = try gateway.register(upstream: URL(string: "https://8.8.8.8/media")!)
                guard route.host == "127.0.0.1", route.pathComponents.count == 3 else { throw CommunityStreamGateway.Failure.invalidStream }
                gateway.stop()
                NSLog("community gateway product proof passed")
            } catch {
                gateway.stop()
                NSLog("community gateway product proof failed")
            }
        }
    }
}
