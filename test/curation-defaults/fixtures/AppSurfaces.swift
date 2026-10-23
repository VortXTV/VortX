import Foundation

// Explicit disposable app-global fixtures. No real configuration, account, preferences or token store.
enum RemoteConfig {
    struct Snapshot: Sendable { let catalogsEndpoint: URL }
    static var snapshot: Snapshot { .init(catalogsEndpoint: URL(string: "https://catalogs.vortx.tv/3")!) }
}
@MainActor final class VortXSyncManager {
    static let shared = VortXSyncManager()
    let isSignedIn = false
}
enum CurationStarterCollections {
    static var collections: [CurationCollection] {
        fatalError("Default app fallback is excluded; every model test must inject its fallback")
    }
}
actor MoatToken {
    static let shared = MoatToken()
    func stamp(_ request: inout URLRequest, isSignedIn: Bool) async {
        request.setValue("fixture-only-moat", forHTTPHeaderField: "x-vx-moat")
        if DefaultsFixture.state.read().retireDuringStamp { _ = SourceIndexLifecycleClock.closeSource() }
    }
}

final class DefaultsLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update<T>(_ operation: (inout Value) -> T) -> T { lock.withLock { operation(&value) } }
}
final class DefaultsSignal: @unchecked Sendable {
    private let state = DefaultsLocked((ready: false, waiters: [CheckedContinuation<Void, Never>]()))
    func signal() {
        let waiters = state.update { value in
            value.ready = true
            let waiters = value.waiters; value.waiters.removeAll(); return waiters
        }
        waiters.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.update { value in
                if value.ready { return true }
                value.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
}
enum DefaultsFixture {
    enum Behavior: Sendable { case response, suspend, failure }
    struct State: Sendable {
        var status = 200
        var body = Data()
        var behavior = Behavior.response
        var retireDuringStamp = false
        var retireDuringResponse = false
        var requests: [URLRequest] = []
        var entered = DefaultsSignal()
    }
    static let state = DefaultsLocked(State())
    static func reset(body: Data = Data(), status: Int = 200, behavior: Behavior = .response,
                      retireDuringStamp: Bool = false, retireDuringResponse: Bool = false) {
        state.update { $0 = State(status: status, body: body, behavior: behavior,
            retireDuringStamp: retireDuringStamp, retireDuringResponse: retireDuringResponse) }
    }
}

// Catch-all session-local interception. There is no forwarding path or real socket transport.
final class DefaultsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = DefaultsFixture.state.update { value in
            value.requests.append(request); return value
        }
        state.entered.signal()
        if state.retireDuringResponse { _ = SourceIndexLifecycleClock.closeSource() }
        switch state.behavior {
        case .suspend: return
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .response:
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: state.status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: state.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
