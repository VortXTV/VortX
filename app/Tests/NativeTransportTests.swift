import Foundation

private final class TransportFixture: URLProtocol, @unchecked Sendable {
    enum Scenario: Sendable { case native, legacy, oldServer, unsupported }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var scenario: Scenario = .native
        var requests: [URLRequest] = []
    }
    private static let state = State()
    static func reset(_ scenario: Scenario) { state.lock.withLock { state.scenario = scenario; state.requests = [] } }
    static var requests: [URLRequest] { state.lock.withLock { state.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = Self.state.lock.withLock { Self.state.requests.append(request); return Self.state.scenario }
        let status: Int
        let body: String
        if request.url!.path == "/nzb/capabilities" {
            status = scenario == .oldServer ? 404 : 200
            body = #"{"version":1,"raw":true,"multipartYenc":true,"checksumsRequired":true,"archives":["rar4-store","rar5-store","7z-copy"]}"#
        } else {
            status = scenario == .unsupported ? 422 : 200
            body = scenario == .unsupported ? #"{"error":"unsupported_archive_or_encoding"}"# : #"{"key":"opaque-key"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private enum NativeTransportTests {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--redirect-fixture" {
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await UsenetNodeClient.createStream(
                    endpoint: .init(base: CommandLine.arguments[2], requiresNativeCapabilities: true),
                    nzbURLs: ["https://fixture.example/one.nzb"], servers: ["nntps://fixture:password@news.example:563/4"],
                    session: session, timeout: 2)
                preconditionFailure("Credential POST followed a redirect")
            } catch UsenetNodeClient.ClientError.createFailed(307) {}
            print("PASS real HTTP credential POST redirect is rejected")
            return
        }
        for required in [false, true] {
            for preference in [false, true] {
                precondition(NativeTransportPolicy.selectsNative(required: required, preference: preference) == (required || preference))
            }
        }
        precondition(NativeTransportPolicy.boundNativePort(processRunning: true, receipt: nil) == nil)
        precondition(NativeTransportPolicy.boundNativePort(processRunning: false, receipt: "11470") == nil)
        precondition(NativeTransportPolicy.boundNativePort(processRunning: true, receipt: "11470\n") == 11470)
        for receipt in ["", "11471", "0", "65536", "server ready"] {
            precondition(NativeTransportPolicy.boundNativePort(processRunning: true, receipt: receipt) == nil)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let endpoint = UsenetNodeClient.Endpoint(base: "http://127.0.0.1:54321", requiresNativeCapabilities: true)
        func create(_ target: UsenetNodeClient.Endpoint = endpoint) async throws -> URL {
            try await UsenetNodeClient.createStream(endpoint: target, nzbURLs: ["https://fixture.example/one.nzb"],
                servers: ["nntps://fixture:password@news.example:563/4"], session: session, timeout: 1)
        }
        TransportFixture.reset(.native)
        let url = try await create()
        precondition(url.absoluteString == "http://127.0.0.1:54321/nzb/stream?key=opaque-key")
        precondition(TransportFixture.requests.map { $0.url!.path } == ["/nzb/capabilities", "/nzb/create"])
        precondition(TransportFixture.requests.map(\.httpMethod) == ["GET", "POST"])
        precondition(TransportFixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == nil })
        precondition(TransportFixture.requests.first?.httpBody == nil)

        TransportFixture.reset(.oldServer)
        do { _ = try await create(); preconditionFailure("Old native server received credentials") }
        catch UsenetNodeClient.ClientError.nativeUnavailable {}
        precondition(TransportFixture.requests.count == 1)

        TransportFixture.reset(.legacy)
        _ = try await create(.init(base: endpoint.base, requiresNativeCapabilities: false))
        precondition(TransportFixture.requests.map { $0.url!.path } == ["/nzb/create"])

        TransportFixture.reset(.unsupported)
        do { _ = try await create(); preconditionFailure("Unsupported archive accepted") }
        catch UsenetNodeClient.ClientError.unsupportedArchive {}

        for raw in ["http://192.168.1.50:11470", "https://server.example", "http://localhost:11470",
                    "http://127.0.0.1:11470/remote", "http://u:p@127.0.0.1:11470", "http://127.0.0.1:11470?x=1"] {
            TransportFixture.reset(.native)
            do { _ = try await create(.init(base: raw, requiresNativeCapabilities: true)); preconditionFailure("Unsafe endpoint accepted") }
            catch UsenetNodeClient.ClientError.unsafeEndpoint {}
            precondition(TransportFixture.requests.isEmpty)
        }
        for body in [#"{"version":true,"raw":true,"multipartYenc":true,"checksumsRequired":true,"archives":["rar4-store","rar5-store","7z-copy"]}"#,
                     #"{"version":2,"raw":true}"#, #"{"values":{}}"#, "<html>ok</html>"] {
            precondition(!UsenetNodeClient.acceptsNativeCapabilities(statusCode: 200, body: Data(body.utf8)))
        }
        TransportFixture.reset(.native)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await create()
        }
        do { _ = try await task.value; preconditionFailure("Cancelled task posted credentials") }
        catch is CancellationError {}
        precondition(TransportFixture.requests.isEmpty)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let mobile = try String(contentsOf: root.appendingPathComponent("app/Sources/NodeServer.swift"), encoding: .utf8)
        let bootstrap = String(mobile.components(separatedBy: "static func startIfNeeded() {")[1].prefix(450))
        precondition(bootstrap.contains("if VortxNativeServerFlag.isOn {") && bootstrap.contains("VortxNativeServer.startIfNeeded()\n            return"))
        let selection = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/VortxNativeServer.swift"), encoding: .utf8)
        precondition(selection.contains("static let isOn = NativeTransportPolicy.selectsNative("))
        let mac = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/MacNodeServer.swift"), encoding: .utf8)
        precondition(mac.contains("native-server-\\(UUID().uuidString).port"))
        precondition(mac.contains("env[\"VORTX_PORT_FILE\"] = nativePortReceipt"))
        precondition(mac.contains("NativeTransportPolicy.boundNativePort("))
        for path in ["app/SourcesiOS/VortXiOSApp.swift", "app/SourcesTV/VortXTVApp.swift"] {
            let app = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let initialBootstrap = app.components(separatedBy: "NodeServer.startIfNeeded()")[1].prefix(250)
            precondition(!initialBootstrap.contains("VortxNativeServer.startIfNeeded()"))
        }
        print("PASS native transport: capability before POST, legacy contract, unsupported archive, local credential boundary, cancellation")
    }
}
