// Authored UNRUN. Actual declarations are generated verbatim; only existing transport injection
// initializer is instrumented. No real API, Keychain service, native engine or UI is contacted.
import Foundation
import Dispatch

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

enum RenewalTestFailure: Error { case failed }

final class RenewalProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var id = "immediate"; var status = 200; var body = Data("{}".utf8)
        var renewal: String?; var held = false; var redirect = false; var transportFailure = false
        var etag: String? = "\"17\""
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var waiting: [String: (RenewalProtocol, Reply)] = [:]
    nonisolated(unsafe) private static var hits = 0
    nonisolated(unsafe) private static var foreignHits = 0
    static func reset(_ values: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        precondition(waiting.isEmpty); replies = values; hits = 0; foreignHits = 0
    }
    static func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (hits, foreignHits) }
    static func isWaiting(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return waiting[id] != nil }
    static func release(_ id: String) {
        lock.lock(); let value = waiting.removeValue(forKey: id); lock.unlock()
        precondition(value != nil); value!.0.respond(value!.1)
    }
    override class func canInit(with request: URLRequest) -> Bool { true } // Every attempted request stays inside this fixture.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.hits += 1
        if request.url?.host != "api.vortx.tv" { Self.foreignHits += 1 }
        guard !Self.replies.isEmpty else { Self.lock.unlock(); client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let next = Self.replies.removeFirst()
        if next.held { Self.waiting[next.id] = (self, next) }
        Self.lock.unlock()
        if !next.held { respond(next) }
    }
    override func stopLoading() {}
    private func respond(_ reply: Reply) {
        if reply.transportFailure { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let url = request.url!
        if reply.redirect {
            let target = URL(string: "https://redirect-target.invalid/collect")!
            var changed = request; changed.url = target
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: changed, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        var headers = ["Content-Length": String(reply.body.count)]
        if let etag = reply.etag { headers["ETag"] = etag }
        if let renewal = reply.renewal { headers["X-VortX-Session"] = renewal }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class RenewalBackend: @unchecked Sendable {
    enum Fault: Equatable, Sendable { case none, read, markerWrite, valueWrite, readback, markerClear }
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var fault: Fault = .none
    private var readbackOverride: String?
    private var writes = 0; private var mutations = 0; private var purges = 0
    private var blockPurge = false
    let purgeEntered = DispatchSemaphore(value: 0); let releasePurge = DispatchSemaphore(value: 0)
    func seed(_ value: String, account: String) { lock.lock(); values[account] = value; lock.unlock() }
    func configure(_ fault: Fault = .none, blockFirstPurge: Bool = false, readback: String? = nil) { lock.lock(); self.fault = fault; blockPurge = blockFirstPurge; readbackOverride = readback; lock.unlock() }
    func snapshot() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values }
    func mutationCount() -> Int { lock.lock(); defer { lock.unlock() }; return mutations }
    func makeStore() -> KeychainFailureClosedStore {
        KeychainFailureClosedStore(readSecure: { [self] account in
            lock.lock(); defer { lock.unlock() }
            if !account.hasPrefix("marker."), fault == .read { return .failure }
            if !account.hasPrefix("marker."), fault == .readback, writes > 0 { return .value(readbackOverride ?? "controlled-readback-mismatch") }
            return values[account].map(CredentialDurableReadResult.value) ?? .missing
        }, writeSecure: { [self] value, account in
            lock.lock(); defer { lock.unlock() }
            mutations += 1
            let marker = account.hasPrefix("marker.")
            if marker && value != nil && fault == .markerWrite { return .failure }
            if marker && value == nil && fault == .markerClear { return .failure }
            if !marker && fault == .valueWrite { return .failure }
            values[account] = value
            if !marker { writes += 1 }
            return .success
        }, invalidationAccount: { "marker." + Data($0.utf8).base64EncodedString() }, invalidationSentinel: "invalidated",
        isLegacyInvalidated: { _ in false }, clearLegacyInvalidated: { _ in }, purgeAllLegacy: {}, purgeLegacy: { [self] _ in
            lock.lock(); purges += 1; let pause = blockPurge && purges == 1; lock.unlock()
            if pause { purgeEntered.signal(); _ = releasePurge.wait(timeout: .now() + 5) }
        })
    }
}

@MainActor enum Keychain {
    static var backend = RenewalBackend()
    static var store = backend.makeStore()
    static func reset() { backend = RenewalBackend(); store = backend.makeStore() }
    static func confirmedString(_ account: String) -> CredentialDurableReadResult { store.confirmedString(account) }
    static func replaceConfirmedUTF8(expected: Data, with next: Data, for account: String) -> CredentialMutationResult {
        store.replaceConfirmedUTF8(expected: expected, with: next, account: account)
    }
}

// Deliberately synthetic manager authority/state, matching the existing auth-recovery fixture seam.
@MainActor final class CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: UInt64 }
    var generation: UInt64 = 1
    func capture() -> Capture { Capture(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}
@MainActor final class RenewalFixture {
    let credentialAuthority = CredentialScopeRegistry()
    let base = "https://api.vortx.tv"; let kcAccount = "controlled.session"
    var account: Account? = Account(id: "00000000-0000-4000-8000-000000000001", email: "fixture@example.invalid", username: "fixture", twoFactorEnabled: false)
    var dataKey: Data? = Data(repeating: 7, count: 32)
    var token: String?; var isSignedIn = true
    var accountReconnectFailureCapture: CredentialScopeRegistry.Capture?
    var pendingPushes = true; var pendingDoc = Data("pending-original".utf8)
}

@MainActor @main struct RenewalTests {
    static func check(_ value: Bool, _ label: String) throws { if !value { print("FAIL " + label); throw RenewalTestFailure.failed } }
    static func token(_ a: String = "00000000-0000-4000-8000-000000000001", v: Any = 1, days: Double = 120, milliseconds: Bool = true) throws -> String {
        let expiry = Date().timeIntervalSince1970 + days * 86400
        let payload: [String: Any] = ["a": a, "v": v, "exp": milliseconds ? Int64(expiry * 1000) : Int64(expiry)]
        return try rawToken(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
    }
    static func rawToken(_ payload: String) throws -> String {
        func encoded(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        return encoded(Data(payload.utf8)) + "." + encoded(Data(repeating: 7, count: 32))
    }
    static func fixture() throws -> RenewalFixture { Keychain.reset(); let f = RenewalFixture(); try f.seed(token(days: 10)); return f }
    static func waiting(_ id: String) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !RenewalProtocol.isWaiting(id) { guard ContinuousClock.now < end else { throw RenewalTestFailure.failed }; try await Task.sleep(for: .milliseconds(1)) }
    }
    static func transportCarryAndNoRedirect() async throws {
        for length in [4096, 4097] {
            RenewalProtocol.reset([.init(renewal: String(repeating: "a", count: length))])
            let response = try await AuthenticatedHTTPTransport.shared.send(URLRequest(url: URL(string: "https://api.vortx.tv/v1/backup")!), allowedHosts: ["api.vortx.tv"], maxResponseBytes: 64)
            try check(response.sessionRenewal?.utf8.count == (length == 4096 ? 4096 : nil), "header-bound")
        }
        RenewalProtocol.reset([.init(renewal: try token(), redirect: true)])
        do { _ = try await AuthenticatedHTTPTransport.shared.send(URLRequest(url: URL(string: "https://api.vortx.tv/redirect")!), allowedHosts: ["api.vortx.tv"], maxResponseBytes: 64); throw RenewalTestFailure.failed }
        catch let error as AuthenticatedHTTPTransportError { try check(error == .redirectRejected, "redirect-rejected") }
        try check(RenewalProtocol.counts().1 == 0, "no-foreign-hit")
    }
    static func requestAdmission() async throws {
        for status in [200, 304] {
            let f = try fixture(); let prior = f.token; let next = try token(); let key = f.dataKey; let owner = f.account
            var original = try OwnerHistoryExactJSON.Object(Data(Keychain.backend.snapshot()[f.kcAccount]!.utf8))
            let future = Data("{\"precise\":18446744073709551615,\"number\":1e0}".utf8)
            original.set("future", future)
            var accountRaw = try OwnerHistoryExactJSON.Object(original.required("account")); accountRaw.set("future", future)
            let originalAccountBytes = try accountRaw.encoded(); original.set("account", originalAccountBytes)
            Keychain.backend.seed(String(decoding: try original.encoded(), as: UTF8.self), account: f.kcAccount)
            RenewalProtocol.reset([.init(status: status, body: status == 304 ? Data() : Data("{}".utf8), renewal: next)])
            let result = await f.perform(capture: f.credentialAuthority.capture(), conditional: status == 304 ? 17 : nil)
            try check(result == status && f.token == next && f.token != prior && f.dataKey == key && f.account == owner, "request-accept")
            let durable = try f.persistedToken(); let metadata = try f.persistedMetadataMatches()
            try check(durable == next && metadata && f.pendingPushes && f.pendingDoc == Data("pending-original".utf8), "tuple-pending-conserved")
            let final = try OwnerHistoryExactJSON.Object(Data(Keychain.backend.snapshot()[f.kcAccount]!.utf8))
            let finalFuture = try final.required("future"), finalAccount = try final.required("account")
            try check(finalFuture == future && finalAccount == originalAccountBytes, "unknown-raw-tuple-members-conserved")
        }
        for path in ["/v1/auth/me", "/v1/qr/join"] {
            let f = try fixture(); let old = f.token; RenewalProtocol.reset([.init(renewal: try token())])
            _ = await f.perform(path, capture: f.credentialAuthority.capture()); try check(f.token == old, "excluded-route")
        }
        for mode in 0..<6 {
            let f = try fixture(); let old = f.token
            RenewalProtocol.reset([.init(status: mode == 2 ? 401 : mode == 3 ? 503 : 200, renewal: try token(), transportFailure: mode == 5)])
            _ = await f.perform(capture: mode == 0 ? nil : f.credentialAuthority.capture(), auth: mode != 4, bearer: mode == 1 ? "one-off" : nil)
            try check(f.token == old, "excluded-capture-bearer-status")
        }
        let f = try fixture(); let old = f.token
        RenewalProtocol.reset([.init(status: 304, body: Data("not-empty".utf8), renewal: try token())])
        let code = await f.perform(capture: f.credentialAuthority.capture(), conditional: 17)
        try check(code == 0 && f.token == old, "invalid304-body")
        RenewalProtocol.reset([.init(status: 304, body: Data(), renewal: try token())])
        let unsolicited = await f.perform(capture: f.credentialAuthority.capture())
        try check(unsolicited == 0 && f.token == old, "unsolicited304")
        for tag in [nil, "\"18\"", "W/\"17\"", "17"] as [String?] {
            RenewalProtocol.reset([.init(status: 304, body: Data(), renewal: try token(), etag: tag)])
            _ = await f.perform(capture: f.credentialAuthority.capture(), conditional: 17)
            try check(f.token == old, "conditional304-etag-must-match-before-renewal")
        }
    }
    static func rejectedClaims() async throws {
        let millis = Int64((Date().timeIntervalSince1970 + 120 * 86400) * 1000)
        let account = "00000000-0000-4000-8000-000000000001"
        let invalid = try [token("other"), token(v: 2), token(v: true), token(v: 1.5), token(days: -1), token(days: 122),
            token(days: 1), token(milliseconds: false), rawToken("{\"a\":\"\(account)\",\"v\":1,\"exp\":\(millis).5}"),
            rawToken("{\"a\":\"\(account)\",\"v\":2,\"v\":1,\"exp\":\(millis)}"),
            rawToken("{\"a\":\"\(account)\",\"v\":1.000000000000000001,\"exp\":\(millis)}"),
            rawToken("{\"a\":\"\(account)\",\"v\":1,\"exp\":1,\"exp\":\(millis)}"),
            rawToken("{\"a\":\"other\",\"a\":\"\(account)\",\"v\":1,\"exp\":\(millis)}")] + ["bad", ".bad", "a.b.c", String(repeating: "a", count: 4097), try token() + "=", String((try token()).split(separator: ".")[0]) + ".short"]
        for candidate in invalid {
            let f = try fixture(); let old = f.token; let stored = Keychain.backend.snapshot()
            RenewalProtocol.reset([.init(renewal: candidate)])
            _ = await f.perform(capture: f.credentialAuthority.capture())
            try check(f.token == old && Keychain.backend.snapshot() == stored, "claims-refusal")
        }
    }
    static func staleAndOverlap() async throws {
        for mutation in 0..<5 {
            let f = try fixture(); let old = f.token; let next = try token(); let capture = f.credentialAuthority.capture()
            RenewalProtocol.reset([.init(id: "old", renewal: next, held: true)])
            let task = Task { @MainActor in await f.perform(capture: capture) }
            try await waiting("old")
            if mutation == 0 { f.credentialAuthority.generation += 2 }
            if mutation == 1 { f.isSignedIn = false }
            if mutation == 2 { f.accountReconnectFailureCapture = capture }
            if mutation == 3 { f.dataKey = Data(repeating: 8, count: 32) }
            if mutation == 4 { f.account = .init(id: "other", email: "other@example.invalid", username: "other", twoFactorEnabled: false) }
            RenewalProtocol.release("old"); _ = await task.value
            try check(f.token == old && f.pendingPushes && f.pendingDoc == Data("pending-original".utf8), "stale-owner-key-marker")
        }
        let f = try fixture(); let capture = f.credentialAuthority.capture(); let first = try token(days: 100); let late = try token(days: 110)
        RenewalProtocol.reset([.init(id: "first", renewal: first, held: true), .init(id: "late", renewal: late, held: true)])
        let a = Task { @MainActor in await f.perform(capture: capture) }; try await waiting("first")
        let b = Task { @MainActor in await f.perform(capture: capture) }; try await waiting("late")
        RenewalProtocol.release("first"); _ = await a.value; RenewalProtocol.release("late"); _ = await b.value
        try check(f.token == first, "two-old-responses-one-winner")
    }
    static func casFailuresAndPending() throws {
        for fault in [RenewalBackend.Fault.none, .read, .markerWrite, .valueWrite, .readback, .markerClear] {
            let backend = RenewalBackend(); backend.seed("old", account: "a"); backend.configure(fault)
            let original = backend.snapshot().mapValues { Data($0.utf8) }
            let store = backend.makeStore(); let result = store.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data("new".utf8), account: "a")
            try check(result == (fault == .none ? .success : .failure), "CAS-fault-result")
            if fault == .read {
                try check(store.durableString("a") == .failure && backend.snapshot().mapValues { Data($0.utf8) } == original, "unavailable-read-preserves-backend-bytes")
                backend.configure(.none)
                try check(store.durableString("a") == .value("old"), "old-durable-value-recovers-after-read-fault-clears")
            }
            if [.markerWrite, .valueWrite].contains(fault) { try check(store.durableString("a") == .value("old"), "recoverable-old") }
            if fault != .none { try check(store.string("a") != "new", "no-volatile-candidate") }
        }
        let backend = RenewalBackend(); backend.seed("old", account: "a"); let store = backend.makeStore(); let before = backend.snapshot()
        try check(store.replaceConfirmedUTF8(expected: Data("wrong".utf8), with: Data("new".utf8), account: "a") == .failure && backend.snapshot() == before && backend.mutationCount() == 0, "CAS-mismatch-zero-write")
        backend.configure(.valueWrite); _ = store.set("pending-ui", for: "a")
        try check(store.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data("new".utf8), account: "a") == .failure && store.string("a") == "pending-ui" && store.durableString("a") == .value("old"), "pending-fallback-conserved")
        let nfc = "{\"token\":\"old\",\"username\":\"\u{e9}\"}", nfd = "{\"token\":\"old\",\"username\":\"e\u{301}\"}"
        let unicode = RenewalBackend(); unicode.seed(nfc, account: "u"); let exactStore = unicode.makeStore()
        try check(exactStore.replaceConfirmedUTF8(expected: Data(nfd.utf8), with: Data("new".utf8), account: "u") == .failure && unicode.mutationCount() == 0, "UTF8-CAS-not-canonical-string-equality")
        let readback = RenewalBackend(); readback.seed("old", account: "u"); readback.configure(.readback, readback: nfd)
        let readbackStore = readback.makeStore()
        try check(readbackStore.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data(nfc.utf8), account: "u") == .failure && readbackStore.confirmedString("u") == .failure, "UTF8-readback-not-canonical-string-equality")
    }
    static func requestPersistenceFailureDoesNotPublish() async throws {
        for fault in [RenewalBackend.Fault.markerWrite, .valueWrite, .readback, .markerClear] {
            let f = try fixture(); let prior = f.token; let owner = f.account; let key = f.dataKey
            Keychain.backend.configure(fault)
            RenewalProtocol.reset([.init(renewal: try token())])
            _ = await f.perform(capture: f.credentialAuthority.capture())
            try check(f.token == prior && f.account == owner && f.dataKey == key && f.pendingPushes && f.pendingDoc == Data("pending-original".utf8), "failed-persistence-no-publication")
        }
    }
    static func mismatchCannotRetireLegitimateTransition() throws {
        let backend = RenewalBackend(); backend.seed("old", account: "a"); backend.configure(blockFirstPurge: true)
        let store = backend.makeStore(); let result = Locked<CredentialMutationResult?>(nil); let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { result.set(store.set("legitimate", for: "a")); group.leave() }
        defer { backend.releasePurge.signal() }
        try check(backend.purgeEntered.wait(timeout: .now() + 5) == .success, "set-staged-before-lock")
        try check(store.replaceConfirmedUTF8(expected: Data("wrong".utf8), with: Data("new".utf8), account: "a") == .failure, "stale-CAS-refused")
        backend.releasePurge.signal(); try check(group.wait(timeout: .now() + 5) == .success, "owned-set-join")
        try check(result.get() == .success && store.confirmedString("a") == .value("legitimate"), "mismatch-must-not-advance-generation")
    }
    static func twoConcurrentCAS() throws {
        let backend = RenewalBackend(); backend.seed("old", account: "a"); let store = backend.makeStore()
        let group = DispatchGroup(); let start = DispatchSemaphore(value: 0)
        let one = Locked<CredentialMutationResult?>(nil), two = Locked<CredentialMutationResult?>(nil)
        for (value, result) in [("one", one), ("two", two)] {
            group.enter(); DispatchQueue.global().async { _ = start.wait(timeout: .now() + 5); result.set(store.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data(value.utf8), account: "a")); group.leave() }
        }
        start.signal(); start.signal(); try check(group.wait(timeout: .now() + 5) == .success, "owned-CAS-join")
        try check([one.get(), two.get()].filter { $0 == .success }.count == 1, "CAS-exactly-one-winner")
    }
    static func main() async {
        do {
            try await transportCarryAndNoRedirect(); try await requestAdmission(); try await rejectedClaims(); try await staleAndOverlap()
            try casFailuresAndPending(); try await requestPersistenceFailureDoesNotPublish(); try mismatchCannotRetireLegitimateTransition(); try twoConcurrentCAS()
            print("PASS eight actual-source renewal groups; synthetic backend/authority/server only")
        } catch { print("FAIL session renewal controls; no tokens emitted"); exit(1) }
    }
}
