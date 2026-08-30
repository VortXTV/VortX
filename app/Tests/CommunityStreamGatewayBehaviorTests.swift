import Foundation
import Network
import Darwin

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) { _ = category; _ = message }
}

// Minimal product-model seam required by CommunityStreamGateway's convenience adapter. These tests exercise
// register + the real loopback listener directly, without compiling the rest of the application model graph.
struct CoreStream {
    let isCommunityJavaScriptProvider: Bool
    let requestHeaders: [String: String]?
    let vortxProvider: String?
}

private final class MockOrigin: @unchecked Sendable {
    struct Hit: Sendable { let url: URL; let headers: [String: String] }
    private let lock = NSLock()
    private var hits: [Hit] = []
    private var cancelledHangs = 0

    func stream(_ request: PinnedHTTPClient.Request,
                onHead: @escaping @Sendable (PinnedHTTPClient.ResponseHead) async throws -> Void,
                onBody: @escaping @Sendable (Data) async throws -> Void) async throws {
        record(Hit(url: request.url, headers: request.headers))
        switch request.url.path {
        case "/same-start":
            try await onHead(.init(statusCode: 302, headers: [
                "location": "https://origin.example/final",
                "set-cookie": "redirectCookie=must-not-propagate; Path=/final; Secure"
            ]))
        case "/cross-start":
            try await onHead(.init(statusCode: 302, headers: ["location": "https://other.example/final"]))
        case "/final":
            try await onHead(.init(statusCode: 206, headers: ["content-length": "2", "content-type": "video/mp4"]))
            try await onBody(Data("OK".utf8))
        case "/slow":
            throw PinnedHTTPClient.Failure.timedOut
        case "/hang":
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch {
                recordHangCancellation()
                throw PinnedHTTPClient.Failure.cancelled
            }
        default:
            try await onHead(.init(statusCode: 200, headers: ["content-length": "2"]))
            try await onBody(Data("OK".utf8))
        }
    }

    func snapshot() -> (hits: [Hit], cancelledHangs: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hits, cancelledHangs)
    }

    private func record(_ hit: Hit) {
        lock.lock(); hits.append(hit); lock.unlock()
    }

    private func recordHangCancellation() {
        lock.lock(); cancelledHangs += 1; lock.unlock()
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record() { lock.lock(); value = true; lock.unlock() }
    func snapshot() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@main
private struct CommunityStreamGatewayBehaviorTests {
    static func main() async {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Community gateway behavior failed: \(message)") }
            checks += 1
        }

        let origin = MockOrigin()
        let gateway = CommunityStreamGateway(streamOperation: { request, onHead, onBody in
            try await origin.stream(request, onHead: onHead, onBody: onBody)
        })

        let credentials = ["Authorization": "Bearer origin-secret", "Cookie": "session=origin-cookie",
                           "Referer": "https://origin.example/page", "Range": "bytes=4096-8191"]
        let originURL = URL(string: "https://origin.example/start")!
        let sameHeaders = CommunityGatewayTransportPolicy.childHeaders(
            credentials, parent: originURL, child: URL(string: "https://origin.example/final")!)
        expect(sameHeaders == credentials, "pure redirect policy preserves same-origin headers")
        let crossHeaders = CommunityGatewayTransportPolicy.childHeaders(
            credentials, parent: originURL, child: URL(string: "https://other.example/final")!)
        expect(crossHeaders["Range"] == "bytes=4096-8191"
               && crossHeaders.keys.allSatisfy { !["authorization", "cookie", "referer"].contains($0.lowercased()) },
               "pure redirect policy strips cross-origin credentials but retains transport-owned Range")

        let cleanHalfClose = GatewayClientLifetime()
        expect(!GatewayDownstreamReceivePolicy.shouldMonitor(
            initialRead: true, complete: true, hasError: false, lifetime: cleanHalfClose),
            "request bytes plus clean initial EOF are treated as a legal half-close")
        let cancellationProbe = CancellationProbe()
        let disconnectLifetime = GatewayClientLifetime()
        disconnectLifetime.install(Task {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancellationProbe.record() }
        })
        expect(!GatewayDownstreamReceivePolicy.shouldMonitor(
            initialRead: false, complete: true, hasError: false, lifetime: disconnectLifetime),
            "EOF observed by the post-request monitor cancels the upstream lifetime")
        try? await Task.sleep(nanoseconds: 30_000_000)
        expect(cancellationProbe.snapshot(), "pure lifecycle seam delivers cancellation to active upstream work")

        do { try await gateway.start() }
        catch {
            // Network.framework listeners are unavailable in some restricted command-line test hosts. The
            // executable remains a real loopback behavior suite and runs in full on an unrestricted macOS host.
            if String(describing: error).contains("rawValue: 22") {
                if ProcessInfo.processInfo.environment["CI"] != nil {
                    fatalError("loopback behavior unavailable in CI: \(error)")
                }
                print("Community stream gateway behavior: PURE PASS (\(checks) checks); LOOPBACK NOT RUN (Network.framework listener unavailable: \(error))")
                return
            }
            fatalError("gateway start: \(error)")
        }
        let addonHeaders = [
            "Authorization": "Bearer origin-secret",
            "Cookie": "session=origin-cookie",
            "Referer": "https://origin.example/page",
            "Range": "bytes=0-1"
        ]

        let same = try! gateway.register(upstream: URL(string: "https://origin.example/same-start")!, headers: addonHeaders)
        let sameWire = try! await loopbackRequest(same, range: "bytes=4096-8191")
        expect(status(sameWire) == 206 && sameWire.suffix(2) == Data("OK".utf8), "same-origin redirect streams the final response")
        let afterSame = origin.snapshot().hits
        expect(afterSame.filter { $0.url.path == "/same-start" }.count == 1
               && afterSame.filter { $0.url.host == "origin.example" && $0.url.path == "/final" }.count == 1,
               "redirect and final origin are each hit exactly once")
        let sameFinal = afterSame.last { $0.url.host == "origin.example" && $0.url.path == "/final" }?.headers ?? [:]
        expect(sameFinal["Range"] == "bytes=4096-8191" && sameFinal["Authorization"] == "Bearer origin-secret",
               "downstream dynamic Range wins while same-origin authorization survives")
        expect(sameFinal["Cookie"] == "session=origin-cookie" && !sameFinal["Cookie", default: ""].contains("redirectCookie"),
               "unscoped response Set-Cookie is not propagated")

        let cross = try! gateway.register(upstream: URL(string: "https://origin.example/cross-start")!, headers: addonHeaders)
        let crossWire = try! await loopbackRequest(cross, range: "bytes=8192-12287")
        expect(status(crossWire) == 206, "cross-origin redirect reaches its final response")
        let crossFinal = origin.snapshot().hits.last { $0.url.host == "other.example" && $0.url.path == "/final" }?.headers ?? [:]
        expect(crossFinal["Range"] == "bytes=8192-12287"
               && crossFinal.keys.allSatisfy { !["authorization", "cookie", "referer"].contains($0.lowercased()) },
               "cross-origin redirect strips credentials while retaining player Range")

        let slow = try! gateway.register(upstream: URL(string: "https://origin.example/slow")!)
        let slowStatus = status(try! await loopbackRequest(slow))
        expect(slowStatus == 504, "pre-head timeout returns 504")

        let hang = try! gateway.register(upstream: URL(string: "https://origin.example/hang")!)
        try! await disconnectAfterRequest(hang)
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(origin.snapshot().cancelledHangs == 1, "downstream disconnect cancels the active upstream operation")

        gateway.stop()
        print("Community stream gateway behavior: PASS (\(checks) checks)")
    }

    private static func status(_ wire: Data) -> Int? {
        guard let line = String(data: wire, encoding: .utf8)?.components(separatedBy: "\r\n").first else { return nil }
        return line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }

    private static func loopbackRequest(_ url: URL, range: String? = nil) async throws -> Data {
        try await Task.detached { try blockingRequest(url, range: range, readResponse: true) }.value
    }

    private static func disconnectAfterRequest(_ url: URL) async throws {
        _ = try await Task.detached { try blockingRequest(url, range: nil, readResponse: false) }.value
    }

    private static func blockingRequest(_ url: URL, range: String?, readResponse: Bool) throws -> Data {
        guard let port = url.port else { throw URLError(.badURL) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }
        var request = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
        if let range { request += "Range: \(range)\r\n" }
        request += "\r\n"
        _ = request.withCString { Darwin.send(descriptor, $0, strlen($0), 0) }
        guard readResponse else { return Data() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}
