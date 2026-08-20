import Foundation

/// Executable lifecycle proof for the community stream gateway. It does not contact a remote origin: the test
/// verifies the loopback binding and opaque-token contract independently from network availability.
@main
struct CommunityStreamGatewayFunctionalProofTests {
    static func main() async {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Community gateway proof failed: \(message)") }
            checks += 1
        }

        let gateway = CommunityStreamGateway.shared
        gateway.stop()
        do {
            _ = try gateway.register(upstream: URL(string: "https://media.example.test/segment.ts")!)
            fatalError("Community gateway proof accepted a route before loopback startup")
        } catch CommunityStreamGateway.Failure.unavailable { checks += 1 }
        catch { fatalError("Community gateway proof wrong startup error: \(error)") }

        do { try await gateway.start() }
        catch { fatalError("Community gateway proof could not bind loopback: \(error)") }
        let signed = URL(string: "https://media.example.test/a%2Fb.ts?sig=a%2Bb&sig=c%2Fd")!
        let local = try! gateway.register(upstream: signed, headers: ["Authorization": "Bearer test"])
        expect(local.scheme == "http" && local.host == "127.0.0.1", "loopback-only local route")
        let path = local.pathComponents
        expect(path.count == 3 && path[1] == "community" && path[2].count == 32, "opaque fixed-size token")
        expect(!local.absoluteString.contains("media.example.test") && !local.absoluteString.contains("sig="), "provider URL and query never leak")
        gateway.stop()
        print("Community stream gateway functional proof: PASS (\(checks) checks)")
    }
}
