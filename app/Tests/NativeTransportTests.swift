import Foundation

private final class TransportFixture: URLProtocol, @unchecked Sendable {
    enum Scenario: Sendable { case native, oldServer, unsupported }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var scenario: Scenario = .native
        var requests: [URLRequest] = []
    }
    private static let state = State()
    static func reset(_ scenario: Scenario) { state.lock.withLock { state.scenario = scenario; state.requests = [] } }
    static var requests: [URLRequest] {
        state.lock.withLock { state.requests.filter { !$0.url!.path.hasSuffix("/cancel") } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = Self.state.lock.withLock { Self.state.requests.append(request); return Self.state.scenario }
        let status: Int
        let body: String
        if request.url!.path == "/nzb/capabilities" {
            status = scenario == .oldServer ? 404 : 200
            body = #"{"version":1,"raw":true,"multipartYenc":true,"checksumsRequired":true,"archives":["rar4-store","rar5-store","7z-copy"],"operationCancellation":true,"operationIdFormat":"uuid","selection":{"fileIdx":true,"fileMustInclude":true,"episode":true,"fileIdxOrder":"nzb-media-or-archive-entry-order","regexSyntax":"bare-or-js-ims"}}"#
        } else if request.url!.path.hasSuffix("/cancel") {
            status = 204
            body = ""
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
                    endpoint: .init(base: CommandLine.arguments[2]),
                    nzbURLs: ["https://fixture.example/one.nzb"], servers: ["nntps://fixture:password@news.example:563/4"],
                    session: session, timeout: 2, ownerIsCurrent: { true })
                preconditionFailure("Credential POST followed a redirect")
            } catch UsenetNodeClient.ClientError.createFailed(307) {}
            print("PASS real HTTP credential POST redirect is rejected")
            return
        }
        for raw in ["http://127.0.0.1:1", "http://127.0.0.1:65535/", "http://[::1]:54321"] {
            precondition(NativeTransportPolicy.localControlBase(raw) != nil,
                         "A literal loopback origin with an explicit valid port must be accepted")
        }
        for override in [nil, "0", "1", "true", "unexpected"] as [String?] {
            var inherited = ["PRESERVED_FIXTURE": "unchanged", "VORTX_PROXY_ALLOW_LOOPBACK": "0"]
            inherited["VORTX_PROXY_INSECURE_TLS"] = override
            let secured = NativeTransportPolicy.nativeServerEnvironment(from: inherited)
            precondition(secured["VORTX_PROXY_INSECURE_TLS"] == "0")
            precondition(secured["PRESERVED_FIXTURE"] == "unchanged")
            precondition(secured["VORTX_PROXY_ALLOW_LOOPBACK"] == "0")
            precondition(inherited["VORTX_PROXY_INSECURE_TLS"] == override,
                         "Hardening the child must not mutate the parent's environment")
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
        let endpoint = UsenetNodeClient.Endpoint(base: "http://127.0.0.1:54321")
        @Sendable func create(_ target: UsenetNodeClient.Endpoint = endpoint) async throws -> UsenetNodeClient.CreatedStream {
            try await UsenetNodeClient.createStream(endpoint: target, nzbURLs: ["https://fixture.example/one.nzb"],
                servers: ["nntps://fixture:password@news.example:563/4"], session: session, timeout: 1,
                ownerIsCurrent: { true })
        }
        TransportFixture.reset(.native)
        let created = try await create()
        let url = created.url
        precondition(url.absoluteString == "http://127.0.0.1:54321/nzb/stream?key=opaque-key")
        precondition(TransportFixture.requests.map { $0.url!.path } == ["/nzb/capabilities", "/nzb/create"])
        precondition(TransportFixture.requests.map(\.httpMethod) == ["GET", "POST"])
        precondition(TransportFixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == nil })
        precondition(TransportFixture.requests.first?.httpBody == nil)
        precondition(created.lease != nil && created.lease?.isClosed == false,
                     "Every native create must return its live operation lease")
        // Retain the result through request assertions, then explicitly retire its operation.
        created.lease?.close()

        TransportFixture.reset(.oldServer)
        do { _ = try await create(); preconditionFailure("Old native server received credentials") }
        catch UsenetNodeClient.ClientError.nativeUnavailable {}
        precondition(TransportFixture.requests.count == 1)

        TransportFixture.reset(.native)
        let baseCreated = try await UsenetNodeClient.createStream(
            base: endpoint.base, nzbURLs: ["https://fixture.example/one.nzb"],
            servers: ["nntps://fixture:password@news.example:563/4"], session: session, timeout: 1,
            ownerIsCurrent: { true })
        precondition(TransportFixture.requests.map { $0.url!.path } == ["/nzb/capabilities", "/nzb/create"])
        precondition(TransportFixture.requests.map(\.httpMethod) == ["GET", "POST"])
        precondition(baseCreated.lease != nil && baseCreated.lease?.isClosed == false,
                     "The base overload cannot bypass capabilities or operation ownership")
        baseCreated.lease?.close()

        TransportFixture.reset(.unsupported)
        do { _ = try await create(); preconditionFailure("Unsupported archive accepted") }
        catch UsenetNodeClient.ClientError.unsupportedArchive {}

        for raw in ["http://192.168.1.50:11470", "https://server.example", "http://localhost:11470",
                    "http://127.0.0.1:11470/remote", "http://u:p@127.0.0.1:11470", "http://127.0.0.1:11470?x=1"] {
            TransportFixture.reset(.native)
            do { _ = try await create(.init(base: raw)); preconditionFailure("Unsafe endpoint accepted") }
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
        precondition(mobile.contains("static func startIfNeeded() {")
                     && mobile.contains("VortxNativeServer.startIfNeeded()")
                     && !mobile.contains("NativeTransportPolicy.selectsNative")
                     && !mobile.contains("nativeServerEnabled") && !mobile.contains("NodeJS"),
                     "The mobile facade must start only the native engine, with no legacy selection path")
        let selection = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/VortxNativeServer.swift"), encoding: .utf8)
        precondition(selection.contains("static var isSupported: Bool")
                     && selection.contains("#if VORTX_ENGINE_SERVER")
                     && !selection.contains("static let isOn"))
        let client = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/UsenetNodeClient.swift"), encoding: .utf8)
        precondition(!client.contains("requiresNativeCapabilities"),
                     "Native capability validation must not have an opt-out endpoint flag")
        let mac = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/MacNodeServer.swift"), encoding: .utf8)
        let nativeLaunch = mac.components(separatedBy: "private static func spawnNative(binPath: String) {")[1]
            .components(separatedBy: "proc.environment = env")[0]
        precondition(nativeLaunch.contains("var env = NativeTransportPolicy.nativeServerEnvironment(from: ProcessInfo.processInfo.environment)"),
                     "The real native launch must use the verified TLS environment policy")
        precondition(mac.contains("native-server-\\(UUID().uuidString).port"))
        precondition(mac.contains("env[\"VORTX_PORT_FILE\"] = nativePortReceipt"))
        precondition(mac.contains("NativeTransportPolicy.boundNativePort("))
        for path in ["app/SourcesiOS/VortXiOSApp.swift", "app/SourcesTV/VortXTVApp.swift"] {
            let app = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let initialBootstrap = app.components(separatedBy: "NodeServer.startIfNeeded()")[1].prefix(250)
            precondition(!initialBootstrap.contains("VortxNativeServer.startIfNeeded()"))
        }
        print("PASS native transport: mandatory capabilities and leases for both overloads, unsupported archive, local credential boundary, cancellation")
    }
}
