// Standalone adversarial tests for Trakt auth session identity and write leases.
//
// Run with:
//   swiftc -D DEBUG -strict-concurrency=complete -warnings-as-errors -o /tmp/trakt-session-security \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/TraktScrobbleProgressPolicy.swift \
//     app/SourcesShared/TraktAuth.swift \
//     app/SourcesShared/VortXEdgeAuth.swift \
//     app/Tests/TraktSessionSecurityTests.swift && /tmp/trakt-session-security

import Foundation

/// Production dependencies are replaced with isolated test seams.
enum Keychain {
    private static let backing = TestKeychainBacking()

    static func string(_ account: String) -> String? { backing.read(account) }
    @discardableResult
    static func set(_ value: String?, for account: String) -> CredentialMutationResult {
        backing.write(value, account)
    }
    static func durableString(_ account: String) -> CredentialDurableReadResult {
        backing.durableRead(account)
    }
    static func confirmedString(_ account: String) -> CredentialDurableReadResult {
        backing.confirmedRead(account)
    }
    static func reset() { backing.reset() }
    static func ignoreNextWrite() { backing.ignoreNextWrite() }
    static func failNextDurableRead() { backing.failNextDurableRead() }
    static func failNextDurableRead(containing substring: String) { backing.failNextDurableRead(containing: substring) }
    static func invalidate(_ account: String) { backing.invalidate(account) }
    static func mutationCount() -> Int { backing.mutationCount() }
}

private final class TestKeychainBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var volatileValues: [String: String] = [:]
    private var invalidated: Set<String> = []
    private var ignoredWrites = 0
    private var durableReadFailures = 0
    private var failedWrites: Set<String> = []
    private var failedDeletes: Set<String> = []
    private var failedWriteSubstrings: [String: Int] = [:]
    private var failedWriteAfterPersistSubstrings: [String: Int] = [:]
    private var failedDeleteSubstrings: [String: Int] = [:]
    private var failedReadSubstrings: [String: Int] = [:]
    private var mutations = 0

    func read(_ account: String) -> String? {
        lock.lock()
        let value = volatileValues[account] ?? values[account]
        lock.unlock()
        return value
    }

    @discardableResult
    func write(_ value: String?, _ account: String) -> CredentialMutationResult {
        lock.lock()
        mutations += 1
        if ignoredWrites > 0 {
            ignoredWrites -= 1
            if let value { volatileValues[account] = value }
            else { volatileValues.removeValue(forKey: account) }
            lock.unlock()
            return .failure
        }
        values[account] = value
        invalidated.remove(account)
        volatileValues.removeValue(forKey: account)
        lock.unlock()
        return .success
    }

    func durableRead(_ account: String) -> CredentialDurableReadResult {
        lock.lock()
        defer { lock.unlock() }
        if let match = failedReadSubstrings.keys.first(where: { account.contains($0) }),
           let remaining = failedReadSubstrings[match], remaining > 0 {
            failedReadSubstrings[match] = remaining - 1
            return .failure
        }
        if durableReadFailures > 0 {
            durableReadFailures -= 1
            return .failure
        }
        guard let value = values[account] else { return .missing }
        return .value(value)
    }

    func confirmedRead(_ account: String) -> CredentialDurableReadResult {
        lock.lock()
        let isInvalidated = invalidated.contains(account)
        lock.unlock()
        return isInvalidated ? .failure : durableRead(account)
    }

    func invalidate(_ account: String) {
        lock.lock()
        invalidated.insert(account)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        values.removeAll()
        volatileValues.removeAll()
        invalidated.removeAll()
        ignoredWrites = 0
        durableReadFailures = 0
        failedWrites.removeAll()
        failedDeletes.removeAll()
        failedWriteSubstrings.removeAll()
        failedWriteAfterPersistSubstrings.removeAll()
        failedDeleteSubstrings.removeAll()
        failedReadSubstrings.removeAll()
        mutations = 0
        lock.unlock()
    }

    func ignoreNextWrite() {
        lock.lock()
        ignoredWrites += 1
        lock.unlock()
    }

    func failNextDurableRead() {
        lock.lock()
        durableReadFailures += 1
        lock.unlock()
    }

    func failNextDurableRead(containing substring: String) {
        lock.lock()
        failedReadSubstrings[substring, default: 0] += 1
        lock.unlock()
    }

    func mutationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mutations
    }
}

enum DiagnosticsLog {
    private static let backing = TestDiagnosticsBacking()

    static func log(_ category: String, _ message: String) {
        backing.append("\(category):\(message)")
    }

    static func reset() { backing.reset() }
    static func messages() -> [String] { backing.snapshot() }
}

private final class TestDiagnosticsBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        values.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct TraktDeviceCode: Codable, Sendable, Equatable {
    let session: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case session
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct TraktToken: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let scope: String?
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        expiresIn = try values.decode(Int.self, forKey: .expiresIn)
        tokenType = try values.decodeIfPresent(String.self, forKey: .tokenType) ?? "bearer"
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        createdAt = try values.decodeIfPresent(Int.self, forKey: .createdAt)
            ?? Int(Date().timeIntervalSince1970)
    }

    init(
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        tokenType: String = "bearer",
        scope: String? = nil,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
        self.createdAt = createdAt
    }

    var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn))
    }

    func isExpired(leeway: TimeInterval? = nil) -> Bool {
        let margin = leeway ?? min(1_800, Double(max(expiresIn, 0)) / 2)
        return Date().addingTimeInterval(margin) >= expiresAt
    }
}

final class MemoryCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var volatileValues: [String: String] = [:]
    private var invalidated: Set<String> = []
    private var ignoredWrites = 0
    private var durableReadFailures = 0
    private var failedWrites: Set<String> = []
    private var failedDeletes: Set<String> = []
    private var failedWriteSubstrings: [String: Int] = [:]
    private var failedWriteAfterPersistSubstrings: [String: Int] = [:]
    private var failedWriteAfterPersistNthSubstrings: [String: Int] = [:]
    private var failedWriteAfterPersistOverrides: [String: [String]] = [:]
    private var failedWriteAfterPersistMissingSubstrings: [String: Int] = [:]
    private var failedDeleteSubstrings: [String: Int] = [:]
    private var failedDeleteAfterPersistKeys: Set<String> = []
    private var failedReadSubstrings: [String: Int] = [:]
    private var durableReadHook: (@Sendable (String, CredentialDurableReadResult) -> CredentialDurableReadResult)?
    private var writeHook: (@Sendable (String) -> Void)?
    private var mutations = 0

    var store: TraktCredentialStore {
        TraktCredentialStore(
            certifiedRead: { key in self.certifiedRead(key) },
            recoveryRead: { key in self.durableRead(key) },
            write: { value, key in self.write(value, key) }
        )
    }

    private func read(_ key: String) -> String? {
        lock.lock()
        let value = volatileValues[key] ?? values[key]
        lock.unlock()
        return value
    }

    private func durableRead(_ key: String) -> CredentialDurableReadResult {
        lock.lock()
        let result: CredentialDurableReadResult
        if let match = failedReadSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedReadSubstrings[match], remaining > 0 {
            failedReadSubstrings[match] = remaining - 1
            result = .failure
        } else if durableReadFailures > 0 {
            durableReadFailures -= 1
            result = .failure
        } else if let value = values[key] {
            result = .value(value)
        } else {
            result = .missing
        }
        let hook = durableReadHook
        lock.unlock()
        return hook?(key, result) ?? result
    }

    private func certifiedRead(_ key: String) -> CredentialDurableReadResult {
        lock.lock()
        let isInvalidated = invalidated.contains(key)
        lock.unlock()
        return isInvalidated ? .failure : durableRead(key)
    }

    @discardableResult
    private func write(_ value: String?, _ key: String) -> CredentialMutationResult {
        lock.lock()
        mutations += 1
        if value == nil, failedDeleteAfterPersistKeys.remove(key) != nil {
            values.removeValue(forKey: key)
            invalidated.insert(key)
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if value == nil, failedDeletes.remove(key) != nil {
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if value != nil, failedWrites.remove(key) != nil {
            if let value { volatileValues[key] = value }
            lock.unlock()
            return .failure
        }
        if let match = failedWriteSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedWriteSubstrings[match], remaining > 0 {
            failedWriteSubstrings[match] = remaining - 1
            if let value { volatileValues[key] = value }
            else { volatileValues.removeValue(forKey: key) }
            lock.unlock()
            return .failure
        }
        if value == nil,
           let match = failedDeleteSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedDeleteSubstrings[match], remaining > 0 {
            failedDeleteSubstrings[match] = remaining - 1
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if let match = failedWriteAfterPersistSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedWriteAfterPersistSubstrings[match], remaining > 0 {
            failedWriteAfterPersistSubstrings[match] = remaining - 1
            values[key] = value
            invalidated.insert(key)
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if let match = failedWriteAfterPersistMissingSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedWriteAfterPersistMissingSubstrings[match], remaining > 0 {
            failedWriteAfterPersistMissingSubstrings[match] = remaining - 1
            values.removeValue(forKey: key)
            invalidated.insert(key)
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if let match = failedWriteAfterPersistOverrides.keys.first(where: { key.contains($0) }),
           var valuesForMatch = failedWriteAfterPersistOverrides[match], !valuesForMatch.isEmpty {
            let persistedValue = valuesForMatch.removeFirst()
            failedWriteAfterPersistOverrides[match] = valuesForMatch
            values[key] = persistedValue
            invalidated.insert(key)
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if let match = failedWriteAfterPersistNthSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedWriteAfterPersistNthSubstrings[match], remaining > 0 {
            if remaining == 1 {
                failedWriteAfterPersistNthSubstrings.removeValue(forKey: match)
                values[key] = value
                invalidated.insert(key)
                volatileValues.removeValue(forKey: key)
                lock.unlock()
                return .failure
            }
            failedWriteAfterPersistNthSubstrings[match] = remaining - 1
        }
        if let match = failedWriteAfterPersistSubstrings.keys.first(where: { key.contains($0) }),
           let remaining = failedWriteAfterPersistSubstrings[match], remaining > 0 {
            failedWriteAfterPersistSubstrings[match] = remaining - 1
            values[key] = value
            invalidated.insert(key)
            volatileValues.removeValue(forKey: key)
            lock.unlock()
            return .failure
        }
        if ignoredWrites > 0 {
            ignoredWrites -= 1
            if let value { volatileValues[key] = value }
            else { volatileValues.removeValue(forKey: key) }
            lock.unlock()
            return .failure
        }
        values[key] = value
        invalidated.remove(key)
        volatileValues.removeValue(forKey: key)
        let hook = writeHook
        lock.unlock()
        hook?(key)
        return .success
    }

    func value(_ key: String) -> String? { read(key) }

    func durableValue(_ key: String) -> CredentialDurableReadResult { durableRead(key) }

    func mutationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mutations
    }

    func durableKeys(containing substring: String) -> [String] {
        lock.lock()
        let keys = values.keys.filter { $0.contains(substring) }
        lock.unlock()
        return keys
    }

    func injectVolatile(_ value: String?, for key: String) {
        lock.lock()
        if let value { volatileValues[key] = value }
        else { volatileValues.removeValue(forKey: key) }
        lock.unlock()
    }

    func ignoreNextWrite() {
        lock.lock()
        ignoredWrites += 1
        lock.unlock()
    }

    func failNextWrite(for key: String) {
        lock.lock()
        failedWrites.insert(key)
        lock.unlock()
    }

    func failNextDelete(for key: String) {
        lock.lock()
        failedDeletes.insert(key)
        lock.unlock()
    }

    func failNextDeleteAfterPersist(for key: String) {
        lock.lock()
        failedDeleteAfterPersistKeys.insert(key)
        lock.unlock()
    }

    func failNextWrite(containing substring: String) {
        lock.lock()
        failedWriteSubstrings[substring, default: 0] += 1
        lock.unlock()
    }

    func failNextWriteAfterPersist(containing substring: String) {
        lock.lock()
        failedWriteAfterPersistSubstrings[substring, default: 0] += 1
        lock.unlock()
    }

    func failWriteAfterPersistOnMatchingWrite(_ occurrence: Int, containing substring: String) {
        guard occurrence > 0 else { return }
        lock.lock()
        failedWriteAfterPersistNthSubstrings[substring] = occurrence
        lock.unlock()
    }

    func failNextWriteAfterPersist(containing substring: String, persistedValue: String) {
        lock.lock()
        failedWriteAfterPersistOverrides[substring, default: []].append(persistedValue)
        lock.unlock()
    }

    func failNextWriteAfterPersistMissing(containing substring: String) {
        lock.lock()
        failedWriteAfterPersistMissingSubstrings[substring, default: 0] += 1
        lock.unlock()
    }

    func failNextDelete(containing substring: String) {
        lock.lock()
        failedDeleteSubstrings[substring, default: 0] += 1
        lock.unlock()
    }

    func failNextDurableRead(containing substring: String) {
        lock.lock()
        failedReadSubstrings[substring, default: 0] += 1
        lock.unlock()
    }

    func failNextDurableRead() {
        lock.lock()
        durableReadFailures += 1
        lock.unlock()
    }

    func installDurableReadHook(
        _ hook: @escaping @Sendable (String, CredentialDurableReadResult) -> CredentialDurableReadResult
    ) {
        lock.lock()
        durableReadHook = hook
        lock.unlock()
    }

    func installWriteHook(_ hook: @escaping @Sendable (String) -> Void) {
        lock.lock()
        writeHook = hook
        lock.unlock()
    }
}

struct BrokerRequestSnapshot: Sendable {
    let url: String
    let method: String?
    let handlesCookies: Bool
    let cachePolicy: UInt
    let cookieHeader: String?
    let signatureHeader: String?
}

private func waitForAsyncSignal(
    _ stream: AsyncStream<Void>,
    timeoutNanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

final class HTTPRequestGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    init() {
        (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    }

    func requestStarted() {
        entered.signal()
        enteredContinuation.yield(())
        enteredContinuation.finish()
    }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func waitUntilEnteredAsync() async -> Bool {
        await waitForAsyncSignal(enteredStream)
    }
    func releaseResponse() { release.signal() }
    func waitForRelease() { _ = release.wait(timeout: .now() + 5) }
}

final class HTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = Data()
    private var headers: [String: String] = [:]
    private var emittedContentLength: String?
    private var gate: HTTPRequestGate?
    private var requests: [BrokerRequestSnapshot] = []

    func set(
        status: Int,
        json: String = "",
        headers: [String: String] = [:],
        gate: HTTPRequestGate? = nil
    ) {
        set(status: status, body: Data(json.utf8), headers: headers, gate: gate)
    }

    func set(
        status: Int,
        body: Data,
        headers: [String: String] = [:],
        gate: HTTPRequestGate? = nil
    ) {
        lock.lock()
        self.status = status
        self.body = body
        self.headers = headers
        emittedContentLength = nil
        self.gate = gate
        requests.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.lock()
        let status = self.status
        let body = body
        let headers = headers
        let gate = gate
        requests.append(BrokerRequestSnapshot(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod,
            handlesCookies: request.httpShouldHandleCookies,
            cachePolicy: request.cachePolicy.rawValue,
            cookieHeader: request.value(forHTTPHeaderField: "Cookie"),
            signatureHeader: request.value(forHTTPHeaderField: "X-Test-OAuth-Signature")
        ))
        lock.unlock()
        gate?.requestStarted()
        gate?.waitForRelease()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://fixture.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        lock.lock()
        emittedContentLength = response.value(forHTTPHeaderField: "Content-Length")
        lock.unlock()
        return (response, body)
    }

    func requestSnapshots() -> [BrokerRequestSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func lastEmittedContentLength() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return emittedContentLength
    }
}

final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = HTTPFixture()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, body) = Self.fixture.response(for: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RedirectCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0
    private var followed = false

    func record(_ request: URLRequest?) {
        lock.lock()
        invocationCount += 1
        followed = request != nil
        lock.unlock()
    }

    func snapshot() -> (invocationCount: Int, followed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (invocationCount, followed)
    }
}

actor WriteRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func count() -> Int {
        values.count
    }

    func first() -> String? {
        values.first
    }
}

private enum MutationFixtureError: Error {
    case transient
}

final class BoundaryVisibility: @unchecked Sendable {
    private let lock = NSLock()
    private var visible = true

    func update(_ sessionID: TraktSessionID?) {
        lock.lock()
        visible = sessionID != nil
        lock.unlock()
    }

    func snapshot() -> Bool {
        lock.lock()
        let value = visible
        lock.unlock()
        return value
    }
}

final class TraktBoundaryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class TraktPublicationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ sessionID: TraktSessionID?) {
        lock.lock()
        values.append(sessionID?.rawValue ?? "nil")
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let result = values
        lock.unlock()
        return result
    }
}

final class TraktBlockingPublicationOrder: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [String] = []

    func observe(_ sessionID: TraktSessionID?) {
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
        append(sessionID?.rawValue ?? "nil")
    }

    func waitForEntry() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func releaseCallback() {
        release.signal()
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let result = events
        lock.unlock()
        return result
    }
}

final class TraktStageWriteGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = true

    func observe(_ account: String) {
        lock.lock()
        guard armed, account.contains(".stage.") else {
            lock.unlock()
            return
        }
        armed = false
        lock.unlock()
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func waitForEntry() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func releaseWrite() {
        release.signal()
    }
}

final class TraktBoundaryAcquisitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CredentialPublicationOutbox.BoundaryAcquisition?

    func record(_ result: CredentialPublicationOutbox.BoundaryAcquisition) {
        lock.lock()
        if self.result == nil { self.result = result }
        lock.unlock()
    }

    func snapshot() -> CredentialPublicationOutbox.BoundaryAcquisition? {
        lock.lock()
        let result = result
        lock.unlock()
        return result
    }
}

@MainActor private var failures: [String] = []
@MainActor private var checks = 0

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

private func makeAuth(
    store: MemoryCredentials,
    brokerBase: String = "https://oauth.vortx.tv",
    oauthRequestSigner: (@Sendable (URLRequest, Data) -> URLRequest?)? = nil,
    refreshJoinObserver: (@Sendable () -> Void)? = nil,
    sessionWriteDrainObserver: (@Sendable () -> Void)? = nil
) -> TraktAuth {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    return TraktAuth(
        sessionConfiguration: configuration,
        credentials: store.store,
        configuration: TraktAuthConfiguration(
            clientID: "test-client",
            apiBase: "https://fixture.invalid",
            brokerBase: brokerBase
        ),
        oauthRequestSigner: oauthRequestSigner ?? { request, _ in
            var signed = request
            signed.setValue("signed", forHTTPHeaderField: "X-Test-OAuth-Signature")
            return signed
        },
        refreshJoinObserver: refreshJoinObserver,
        sessionWriteDrainObserver: sessionWriteDrainObserver
    )
}

private func adoptLiveToken(_ auth: TraktAuth, label: String) async {
    await auth.adoptTokens(
        access: "\(label)-access",
        refresh: "\(label)-refresh",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3600
    )
}

/// Pending and dispatching intents are durable fences. These paths deliberately exercise an attempted
/// drain that cannot persist its dispatch claim, an active global boundary denial, and a seeded crash
/// between the dispatch claim and callback. None may leak B through a public credential surface.
private func testTraktOutboxFencesAndDispatchingRepair() async -> Bool {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await adoptLiveToken(auth, label: "fence-A")
    guard let sessionA = await auth.sessionID else { return false }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let publication = TraktTokenSlots.publication(namespace)
    let recorder = TraktPublicationRecorder()
    let observer = "trakt-outbox-fence-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { TraktAuthBoundary.removeObserver(key: observer) }

    _ = store.store.write("pending:\(sessionA.rawValue)", publication)
    let pendingSession = await auth.sessionID
    let pendingSyncable = await auth.syncableTokens()
    let pendingPassiveClosed = pendingSession == nil && pendingSyncable == nil
    store.failNextWrite(for: publication)
    let pendingUnbound = try? await auth.validToken()
    store.failNextWrite(for: publication)
    let pendingBound = try? await auth.validToken(for: sessionA)
    let pendingMutationClosed = pendingUnbound == nil
        && pendingBound == nil
        && store.store.certifiedRead(publication) == .value("pending:\(sessionA.rawValue)")
        && recorder.snapshot().isEmpty

    _ = store.store.write("dispatching:\(sessionA.rawValue)", publication)
    let dispatchingSession = await auth.sessionID
    let dispatchingSyncable = await auth.syncableTokens()
    let dispatchingUnbound = try? await auth.validToken()
    let dispatchingBound = try? await auth.validToken(for: sessionA)
    let dispatchingClosed = dispatchingSession == nil
        && dispatchingSyncable == nil
        && dispatchingUnbound == nil
        && dispatchingBound == nil
        && recorder.snapshot().isEmpty

    _ = store.store.write("pending:\(sessionA.rawValue)", publication)
    let boundaryDenied: Bool
    if CredentialPublicationOutbox.acquireBoundary() == .acquired {
        let deniedUnbound = try? await auth.validToken()
        let deniedBound = try? await auth.validToken(for: sessionA)
        let deniedSession = await auth.sessionID
        let deniedSyncable = await auth.syncableTokens()
        boundaryDenied = deniedUnbound == nil
            && deniedBound == nil
            && deniedSession == nil
            && deniedSyncable == nil
            && recorder.snapshot().isEmpty
        CredentialPublicationOutbox.endBoundary()
    } else {
        boundaryDenied = false
    }

    _ = store.store.write("dispatching:\(sessionA.rawValue)", publication)
    let signOutSucceeded = await auth.signOut()
    let signedOutSession = await auth.sessionID
    let repairedBySignOut = signOutSucceeded && signedOutSession == nil
    let adoptionResult = await auth.adoptTokens(
        access: "fence-B-access",
        refresh: "fence-B-refresh",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3_600
    )
    let reAdoptedSession = await auth.sessionID
    let reAdopted = adoptionResult == .success && reAdoptedSession != nil

    Keychain.reset()
    let staticNamespace = CredentialScopeRegistry.shared.currentNamespace()
    let staticPointer = UUID().uuidString.lowercased()
    let staticValues = ["static-access", "static-refresh", "3600", "static-session"]
    let staticBase = [
        TraktTokenSlots.access(staticNamespace),
        TraktTokenSlots.refresh(staticNamespace),
        TraktTokenSlots.expiry(staticNamespace),
        TraktTokenSlots.session(staticNamespace)
    ]
    for (account, value) in zip(staticBase, staticValues) {
        _ = Keychain.set(value, for: account + ".stage." + staticPointer)
    }
    _ = Keychain.set(staticPointer, for: TraktTokenSlots.active(staticNamespace))
    _ = Keychain.set("pending:static-session", for: TraktTokenSlots.publication(staticNamespace))
    let staticPendingClosed = TraktAuth.storedSessionID == nil
    _ = Keychain.set("dispatching:static-session", for: TraktTokenSlots.publication(staticNamespace))
    let staticDispatchingClosed = TraktAuth.storedSessionID == nil
    Keychain.reset()

    return pendingPassiveClosed
        && pendingMutationClosed
        && dispatchingClosed
        && boundaryDenied
        && repairedBySignOut
        && reAdopted
        && staticPendingClosed
        && staticDispatchingClosed
}

/// Publication intent is written before B can become active, and B's final candidate/provenance survives
/// a final delete fault so a same-session refresh can recover its rotated access token.
private func testTraktPublicationIntentAndSameSessionRecovery() async -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let active = TraktTokenSlots.active(namespace)
    let cleanup = TraktTokenSlots.cleanup(namespace)
    let candidate = TraktTokenSlots.candidate(namespace)
    let publication = TraktTokenSlots.publication(namespace)

    let nilActiveStore = MemoryCredentials()
    let pointerB = UUID().uuidString.lowercased()
    let valuesB = ["B-access", "B-refresh", "4102444800", "B-session"]
    for (account, value) in zip(base, valuesB) {
        _ = nilActiveStore.store.write(value, account + ".stage." + pointerB)
    }
    _ = nilActiveStore.store.write("candidate:\(pointerB)", candidate)
    nilActiveStore.failNextWrite(for: publication)
    let nilActive = CredentialTupleTransaction.transition(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        candidateValues: valuesB,
        publicationMarker: publication,
        publicationValue: "B-session",
        certifiedRead: nilActiveStore.store.certifiedRead,
        recoveryRead: nilActiveStore.store.recoveryRead,
        write: nilActiveStore.store.write
    )
    let nilActiveClosed = nilActive == .failedBeforeActivation
        && nilActiveStore.store.certifiedRead(active) == .missing
        && nilActiveStore.store.certifiedRead(candidate) == .value("candidate:\(pointerB)")
        && nilActiveStore.store.certifiedRead(publication) == .missing

    let missingIntentStore = MemoryCredentials()
    let pointerA = UUID().uuidString.lowercased()
    for (account, value) in zip(base, valuesB) {
        _ = missingIntentStore.store.write(value, account + ".stage." + pointerB)
    }
    _ = missingIntentStore.store.write(pointerB, active)
    _ = missingIntentStore.store.write("candidate:\(pointerB)", candidate)
    _ = missingIntentStore.store.write("post:\(pointerA)", cleanup)
    let missingIntent = CredentialTupleTransaction.transition(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        candidateValues: ["C-access", "C-refresh", "4102444801", "C-session"],
        publicationMarker: publication,
        publicationValue: "C-session",
        certifiedRead: missingIntentStore.store.certifiedRead,
        recoveryRead: missingIntentStore.store.recoveryRead,
        write: missingIntentStore.store.write
    )
    let missingIntentClosed = missingIntent == .cleanupPending(
        CredentialTupleAuthority(pointer: pointerB, values: valuesB)
    )
        && missingIntentStore.store.certifiedRead(candidate) == .value("candidate:\(pointerB)")
        && missingIntentStore.store.certifiedRead(cleanup) == .value("post:\(pointerA)")
        && missingIntentStore.durableKeys(containing: ".stage.").count == base.count

    let recoveryStore = MemoryCredentials()
    let priorPointer = UUID().uuidString.lowercased()
    let session = "same-session"
    let priorValues = ["A-access", "A-refresh", "4102444800", session]
    let rotatedValues = ["B-access", "B-refresh", "4102444801", session]
    for (account, value) in zip(base, priorValues) {
        _ = recoveryStore.store.write(value, account + ".stage." + priorPointer)
    }
    _ = recoveryStore.store.write(priorPointer, active)
    recoveryStore.failNextDeleteAfterPersist(for: candidate)
    let firstRecovery = CredentialTupleTransaction.transition(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        candidateValues: rotatedValues,
        certifiedRead: recoveryStore.store.certifiedRead,
        recoveryRead: recoveryStore.store.recoveryRead,
        write: recoveryStore.store.write
    )
    let retainedProvenance: Bool
    if case let .value(rawCleanup) = recoveryStore.durableValue(cleanup) {
        retainedProvenance = CredentialTupleTransaction.cleanupPriorSession(rawCleanup) == session
    } else {
        retainedProvenance = false
    }
    let recoveryAuth = makeAuth(store: recoveryStore)
    let recoveredToken = try? await recoveryAuth.validToken()
    let recoveredTuple = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        certifiedRead: recoveryStore.store.certifiedRead
    )
    let sameSessionRecovered: Bool
    switch firstRecovery {
    case .cleanupPending, .activated, .alreadyActive:
        sameSessionRecovered = true
    case .failedBeforeActivation, .activationStateUnknown:
        sameSessionRecovered = false
    }
    let recoveredAuthority: Bool
    if case let .authority(authority) = recoveredTuple {
        recoveredAuthority = authority.values == rotatedValues
    } else {
        recoveredAuthority = false
    }
    let rotatedRecovered = recoveredToken == "B-access"
        && recoveredAuthority
        && recoveryStore.store.certifiedRead(candidate) == .missing
        && recoveryStore.store.certifiedRead(cleanup) == .missing

    return nilActiveClosed
        && missingIntentClosed
        && sameSessionRecovered
        && retainedProvenance
        && rotatedRecovered
}

private func testTraktDevicePollPersistsCredentialBoundary() async -> Bool {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"broker-session-1","user_code":"user-1","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    guard let device = try? await auth.requestDeviceCode() else { return false }
    let now = Int(Date().timeIntervalSince1970)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"status":"authorized","token":{"access_token":"poll-access","refresh_token":"poll-refresh","expires_in":3600,"token_type":"bearer","created_at":\(now)}}
        """
    )
    guard case let .authorized(token) = try? await auth.poll(session: device.session),
          let session = await auth.sessionID,
          let syncable = await auth.syncableTokens() else { return false }
    return token.accessToken == "poll-access"
        && syncable.access == "poll-access"
        && syncable.refresh == "poll-refresh"
        && session.rawValue != ""
}

private func testTraktBrokerHostAndRequestPolicy() async -> (
    hostRejected: Bool,
    requestHardened: Bool
) {
    let invalid = makeAuth(
        store: MemoryCredentials(),
        brokerBase: "https://attacker.invalid"
    )
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"must-not-send","user_code":"none","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    let hostRejected: Bool
    do {
        _ = try await invalid.requestDeviceCode()
        hostRejected = false
    } catch let error as TraktAuthError {
        hostRejected = error == .brokerUnavailable(status: 0)
            && FixtureURLProtocol.fixture.requestSnapshots().isEmpty
    } catch {
        hostRejected = false
    }

    let auth = makeAuth(store: MemoryCredentials())
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"policy-session","user_code":"policy-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    let device = try? await auth.requestDeviceCode()
    let snapshots = FixtureURLProtocol.fixture.requestSnapshots()
    let requestHardened = device?.session == "policy-session"
        && snapshots.count == 1
        && snapshots[0].url == "https://oauth.vortx.tv/v1/oauth/trakt/device/start"
        && snapshots[0].method == "POST"
        && !snapshots[0].handlesCookies
        && snapshots[0].cachePolicy == URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue
        && snapshots[0].cookieHeader == nil
        && snapshots[0].signatureHeader == "signed"
    return (hostRejected, requestHardened)
}

private func testTraktBrokerRedirectAndBounds() async -> (
    redirectRejected: Bool,
    redirectDelegateRejected: Bool,
    declaredOversizedRejected: Bool,
    streamedOversizedRejected: Bool
) {
    let auth = makeAuth(store: MemoryCredentials())
    FixtureURLProtocol.fixture.set(
        status: 302,
        headers: ["Location": "https://attacker.invalid/collect"]
    )
    let redirectFault: Bool
    do {
        _ = try await auth.requestDeviceCode()
        redirectFault = false
    } catch let error as TraktAuthError {
        redirectFault = error == .brokerUnavailable(status: 302)
    } catch {
        redirectFault = false
    }
    let redirectRequests = FixtureURLProtocol.fixture.requestSnapshots()
    let redirectRejected = redirectFault
        && redirectRequests.count == 1
        && redirectRequests.allSatisfy { $0.url.hasPrefix("https://oauth.vortx.tv/") }

    let redirectDelegate = TraktOAuthNoRedirectDelegate()
    let redirectSession = URLSession(
        configuration: .ephemeral,
        delegate: redirectDelegate,
        delegateQueue: nil
    )
    defer { redirectSession.invalidateAndCancel() }
    let originalURL = URL(string: "https://oauth.vortx.tv/v1/oauth/trakt/device/start")!
    let redirectURL = URL(string: "https://attacker.invalid/collect")!
    let redirectTask = redirectSession.dataTask(with: originalURL)
    let redirectResponse = HTTPURLResponse(
        url: originalURL,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirectURL.absoluteString]
    )!
    let redirectRecorder = RedirectCompletionRecorder()
    redirectDelegate.urlSession(
        redirectSession,
        task: redirectTask,
        willPerformHTTPRedirection: redirectResponse,
        newRequest: URLRequest(url: redirectURL)
    ) { request in
        redirectRecorder.record(request)
    }
    let redirectDecision = redirectRecorder.snapshot()
    let redirectDelegateRejected = redirectDecision.invocationCount == 1
        && !redirectDecision.followed

    let oversized = Data(repeating: 0x61, count: 64 * 1024 + 1)
    FixtureURLProtocol.fixture.set(
        status: 200,
        body: oversized,
        headers: ["Content-Length": String(oversized.count)]
    )
    let declaredOversizedRejected: Bool
    do {
        _ = try await auth.requestDeviceCode()
        declaredOversizedRejected = false
    } catch let error as TraktAuthError {
        if case .transport = error { declaredOversizedRejected = true }
        else { declaredOversizedRejected = false }
    } catch {
        declaredOversizedRejected = false
    }

    let responseMarker = "oversize-secret-marker"
    var streamedOversized = Data("{\"access_token\":\"\(responseMarker)\"}".utf8)
    streamedOversized.append(Data(repeating: 0x62, count: 64 * 1024 + 1 - streamedOversized.count))
    DiagnosticsLog.reset()
    FixtureURLProtocol.fixture.set(status: 200, body: streamedOversized)
    let streamedOversizedRejected: Bool
    do {
        _ = try await auth.requestDeviceCode()
        streamedOversizedRejected = false
    } catch let error as TraktAuthError {
        let publicMessage = error.errorDescription ?? ""
        let logs = DiagnosticsLog.messages().joined(separator: "\n")
        if case .transport = error {
            streamedOversizedRejected = FixtureURLProtocol.fixture.lastEmittedContentLength() == nil
                && !publicMessage.contains(responseMarker)
                && !publicMessage.contains("access_token")
                && !logs.contains(responseMarker)
                && !logs.contains("access_token")
        } else {
            streamedOversizedRejected = false
        }
    } catch {
        streamedOversizedRejected = false
    }
    return (
        redirectRejected,
        redirectDelegateRejected,
        declaredOversizedRejected,
        streamedOversizedRejected
    )
}

private func testTraktStaleBrokerLoginResponse() async -> Bool {
    let auth = makeAuth(store: MemoryCredentials())
    let gate = HTTPRequestGate()
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"stale-session","user_code":"stale-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """,
        gate: gate
    )
    let request = Task {
        do {
            _ = try await auth.requestDeviceCode()
            return false
        } catch let error as TraktAuthError {
            return error == .sessionChanged
        } catch {
            return false
        }
    }
    guard gate.waitUntilEntered() else {
        gate.releaseResponse()
        _ = await request.value
        return false
    }
    await auth.cancelLoginAttempt()
    gate.releaseResponse()
    let delayedResponseRejected = await request.value

    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"opaque-session-A","user_code":"code-A","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    guard let first = try? await auth.requestDeviceCode() else { return false }
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"opaque-session-B","user_code":"code-B","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    guard (try? await auth.requestDeviceCode()) != nil else { return false }
    FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"pending"}"#)
    let staleSessionRejected: Bool
    do {
        _ = try await auth.poll(session: first.session)
        staleSessionRejected = false
    } catch let error as TraktAuthError {
        staleSessionRejected = error == .sessionChanged
            && FixtureURLProtocol.fixture.requestSnapshots().isEmpty
    } catch {
        staleSessionRejected = false
    }
    return delayedResponseRejected && staleSessionRejected
}

private func testTraktRevokeOwnerSwitchFence() async -> Bool {
    let accountA = CredentialScope(canonicalRemoteAccountID: "f5555555-5555-4555-8555-555555555555")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "f6666666-6666-4666-8666-666666666666")!
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountA) }
    let auth = makeAuth(store: MemoryCredentials())
    let adoptedA = await auth.adoptTokens(
        access: "revoke-A-access",
        refresh: "revoke-A-refresh",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3_600
    )
    guard adoptedA == .success, await auth.sessionID != nil else { return false }

    let gate = HTTPRequestGate()
    FixtureURLProtocol.fixture.set(status: 200, json: "{}", gate: gate)
    let revoke = Task { await auth.revokeAndSignOut() }
    guard gate.waitUntilEntered() else {
        gate.releaseResponse()
        _ = await revoke.value
        return false
    }

    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountB) }
    let adoptedB = await auth.adoptTokens(
        access: "revoke-B-access",
        refresh: "revoke-B-refresh",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3_600
    )
    let sessionB = await auth.sessionID
    gate.releaseResponse()
    _ = await revoke.value
    let finalSession = await auth.sessionID
    let finalTokens = await auth.syncableTokens()
    let currentOwner = await MainActor.run { CredentialScopeRegistry.shared.capture().scope }
    return adoptedB == .success
        && currentOwner == accountB
        && sessionB != nil
        && finalSession == sessionB
        && finalTokens?.access == "revoke-B-access"
        && finalTokens?.refresh == "revoke-B-refresh"
}

/// A revoke is only acknowledged to the UI after the local durable clear succeeds. The broker response is
/// deliberately unsuccessful here: remote revocation remains best effort, while the local boundary is the
/// user-visible disconnect authority.
private func testTraktRevokeDefersUIResetUntilDurableClearSucceeds() async -> Bool {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await adoptLiveToken(auth, label: "revoke-durable")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let session = await auth.sessionID,
          let activePointer = store.value(TraktTokenSlots.active(namespace)) else { return false }

    let recorder = TraktPublicationRecorder()
    let observer = "trakt-revoke-durable-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { TraktAuthBoundary.removeObserver(key: observer) }

    let activeAccount = TraktTokenSlots.active(namespace)
    store.installDurableReadHook { account, result in
        account == activeAccount ? .failure : result
    }
    FixtureURLProtocol.fixture.set(status: 503, json: "{}")
    var resetCallbacks = 0
    let first = await auth.revokeAndSignOut()
    if first { resetCallbacks += 1 }
    store.installDurableReadHook { _, result in result }
    let sessionAfterFailure = await auth.sessionID
    let tokensAfterFailure = await auth.syncableTokens()
    let retainedAfterFailure = !first
        && resetCallbacks == 0
        && sessionAfterFailure == session
        && tokensAfterFailure?.access == "revoke-durable-access"
        && store.durableValue(activeAccount) == .value(activePointer)
        && recorder.snapshot().isEmpty

    let retry = await auth.revokeAndSignOut()
    if retry { resetCallbacks += 1 }
    let sessionAfterRetry = await auth.sessionID
    let tokensAfterRetry = await auth.syncableTokens()
    let clearedOnRetry = retry
        && resetCallbacks == 1
        && sessionAfterRetry == nil
        && tokensAfterRetry == nil
        && store.store.certifiedRead(TraktTokenSlots.active(namespace)) == .missing
        && recorder.snapshot() == ["nil"]
    return retainedAfterFailure && clearedOnRetry
}

private func testBlockedOldSessionQueue(label: String) async -> Bool {
    let auth = makeAuth(store: MemoryCredentials())
    await adoptLiveToken(auth, label: "A")
    guard let sessionA = await auth.sessionID else { return false }

    let queue = TraktScrobbleLifecycleQueue()
    let recorder = WriteRecorder()
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    queue.enqueue {
        for await _ in stream { break }
    }
    queue.enqueue {
        // Both live lifecycle and pending completion retry reach this same final auth authority.
        guard TraktPlaybackSnapshotPolicy.canRead(
            snapshotSession: sessionA,
            currentSession: await auth.sessionID
        ) else { return }
        do {
            try await auth.performSessionBoundWrite(expectedSession: sessionA) { _ in
                await recorder.append(label)
            }
        } catch {
            return
        }
    }

    await auth.signOut()
    await adoptLiveToken(auth, label: "B")
    continuation.yield(())
    continuation.finish()
    await queue.drain()
    return await recorder.count() == 0
}

/// Model an immediate mutation that captures A before its first await. Watchlist and rating fixtures
/// first fail under A, then exercise their captured-session retry after B replaces A. Check-in and
/// cancel fixtures exercise the direct final-transport boundary after the same replacement.
private func testOldAccountImmediateMutation(
    label: String,
    retriesAfterFailure: Bool
) async -> Bool {
    let auth = makeAuth(store: MemoryCredentials())
    await adoptLiveToken(auth, label: "A")
    guard let capturedSession = await auth.sessionID else { return false }

    if retriesAfterFailure {
        do {
            try await auth.performSessionBoundWrite(
                expectedSession: capturedSession
            ) { _ -> Void in
                throw MutationFixtureError.transient
            }
        } catch {
            // The caller retains capturedSession for its pending retry.
        }
    }

    await auth.signOut()
    await adoptLiveToken(auth, label: "B")
    let recorder = WriteRecorder()
    do {
        try await auth.performSessionBoundWrite(
            expectedSession: capturedSession
        ) { _ in
            await recorder.append(label)
        }
    } catch {
        // Expected: A can no longer acquire a provider-write lease under B.
    }
    let currentSession = await auth.sessionID
    let writeCount = await recorder.count()
    return currentSession != capturedSession && writeCount == 0
}

private func testSlowWriteCredentialLease() async -> (
    sessionA: TraktSessionID?,
    sessionDuringWrite: TraktSessionID?,
    tokenUsed: String?,
    finalSession: TraktSessionID?
) {
    let auth = makeAuth(store: MemoryCredentials())
    await adoptLiveToken(auth, label: "A")
    let sessionA = await auth.sessionID
    guard let sessionA else { return (nil, nil, nil, nil) }

    let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
    let recorder = WriteRecorder()
    let writeTask = Task {
        try? await auth.performSessionBoundWrite(expectedSession: sessionA) { token in
            enteredContinuation.yield(())
            for await _ in releaseStream { break }
            await recorder.append(token)
        }
    }

    for await _ in enteredStream { break }
    enteredContinuation.finish()
    let boundaryTask = Task {
        await auth.signOut()
        await adoptLiveToken(auth, label: "B")
    }
    try? await Task.sleep(for: .milliseconds(20))
    let sessionDuringWrite = await auth.sessionID
    releaseContinuation.yield(())
    releaseContinuation.finish()
    _ = await writeTask.result
    _ = await boundaryTask.result
    let finalSession = await auth.sessionID
    let tokenUsed = await recorder.first()
    return (sessionA, sessionDuringWrite, tokenUsed, finalSession)
}

private func waitForPendingBoundary(_ auth: TraktAuth) async -> Bool {
    for _ in 0..<1_000 {
        if await auth.isCredentialBoundaryPending { return true }
        await Task.yield()
    }
    return false
}

private func testOwnerSwitchMidAwaitAdoption() async -> Bool {
    let accountA = CredentialScope(canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountA) }
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await adoptLiveToken(auth, label: "A")
    guard let sessionA = await auth.sessionID else { return false }

    let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
    let activeWrite = Task {
        try? await auth.performSessionBoundWrite(expectedSession: sessionA) { _ in
            enteredContinuation.yield(())
            for await _ in releaseStream { break }
        }
    }
    for await _ in enteredStream { break }
    enteredContinuation.finish()

    let captureA = CredentialScopeRegistry.shared.capture()
    let staleAdoption = Task {
        await auth.adoptTokens(
            access: "A-new-access",
            refresh: "A-new-refresh",
            expiryUnix: Int(Date().timeIntervalSince1970) + 3600,
            ownerCapture: captureA)
    }
    let pending = await waitForPendingBoundary(auth)
    guard pending else {
        releaseContinuation.yield(())
        releaseContinuation.finish()
        _ = await activeWrite.result
        _ = await staleAdoption.result
        return false
    }
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountB) }
    releaseContinuation.yield(())
    releaseContinuation.finish()
    _ = await activeWrite.result
    _ = await staleAdoption.result

    let oldAccountKept = store.value(TraktTokenSlots.access(accountA.storageNamespace)) == "A-access"
    let newAccountUntouched = store.value(TraktTokenSlots.access(accountB.storageNamespace)) == nil
    return oldAccountKept && newAccountUntouched
}

private func testTraktReplacementKeepsTheLastCertifiedTuple() async -> (
    mixedTuplePreserved: Bool,
    mixedTupleRetry: Bool,
    stagedWriteFailurePreserved: Bool,
    stagedWriteRetry: Bool,
    activationFailurePreserved: Bool,
    activationRetry: Bool,
    stagedReadFailurePreserved: Bool,
    stagedReadRetry: Bool
) {
    func expiry() -> Int { Int(Date().timeIntervalSince1970) + 3_600 }

    let mixedStore = MemoryCredentials()
    let mixedAuth = makeAuth(store: mixedStore)
    await adoptLiveToken(mixedAuth, label: "A")
    let mixedSession = await mixedAuth.sessionID
    guard let mixedSession else {
        return (false, false, false, false, false, false, false, false)
    }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    mixedStore.failNextDelete(for: TraktTokenSlots.access(namespace))
    mixedStore.failNextWrite(for: TraktTokenSlots.access(namespace))
    await mixedAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let mixedFailureSession = await mixedAuth.sessionID
    let mixedFailureTokens = await mixedAuth.syncableTokens()
    let mixedTuplePreserved = mixedFailureSession == mixedSession
        && mixedFailureTokens?.access == "A-access"
        && mixedStore.durableValue(TraktTokenSlots.refresh(namespace)) == .value("A-refresh")
    await mixedAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let mixedRetryTokens = await mixedAuth.syncableTokens()
    let mixedRetrySession = await mixedAuth.sessionID
    let mixedTupleRetry = mixedRetryTokens?.access == "B-access"
        && mixedRetrySession != mixedSession

    let stagedStore = MemoryCredentials()
    let stagedAuth = makeAuth(store: stagedStore)
    await adoptLiveToken(stagedAuth, label: "A")
    let stagedSession = await stagedAuth.sessionID
    stagedStore.failNextWrite(containing: ".stage.")
    await stagedAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let stagedFailureSession = await stagedAuth.sessionID
    let stagedFailureTokens = await stagedAuth.syncableTokens()
    let stagedWriteFailurePreserved = stagedFailureSession == stagedSession
        && stagedFailureTokens?.access == "A-access"
    await stagedAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let stagedWriteRetry = (await stagedAuth.syncableTokens())?.access == "B-access"

    let activationStore = MemoryCredentials()
    let activationAuth = makeAuth(store: activationStore)
    await adoptLiveToken(activationAuth, label: "A")
    let activationSession = await activationAuth.sessionID
    activationStore.failNextWrite(containing: ".active.")
    await activationAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let activationFailureSession = await activationAuth.sessionID
    let activationFailureTokens = await activationAuth.syncableTokens()
    let activationFailurePreserved = activationFailureSession == activationSession
        && activationFailureTokens?.access == "A-access"
    await activationAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let activationRetry = (await activationAuth.syncableTokens())?.access == "B-access"

    let readStore = MemoryCredentials()
    let readAuth = makeAuth(store: readStore)
    await adoptLiveToken(readAuth, label: "A")
    let readSession = await readAuth.sessionID
    readStore.failNextDurableRead(containing: ".stage.")
    await readAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let stagedReadFailureSession = await readAuth.sessionID
    let stagedReadFailureTokens = await readAuth.syncableTokens()
    let stagedReadFailurePreserved = stagedReadFailureSession == readSession
        && stagedReadFailureTokens?.access == "A-access"
    await readAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: expiry())
    let stagedReadRetry = (await readAuth.syncableTokens())?.access == "B-access"

    return (
        mixedTuplePreserved,
        mixedTupleRetry,
        stagedWriteFailurePreserved,
        stagedWriteRetry,
        activationFailurePreserved,
        activationRetry,
        stagedReadFailurePreserved,
        stagedReadRetry
    )
}

private func testTraktCredentialTransactionHostiles() async -> (
    exactStaging: Bool,
    pointerCandidate: Bool,
    pointerOld: Bool,
    pointerUnknown: Bool,
    candidateRetention: Bool,
    legacyPreRecovery: Bool,
    repairMarkerGate: Bool,
    exactDurableReads: Bool,
    postCleanupRetry: Bool,
    postMirrorRetry: Bool,
    signOutRetry: Bool,
    malformedPointerClosed: Bool,
    createdAtBestEffort: Bool
) {
    let base = ["txn.trakt.access", "txn.trakt.refresh", "txn.trakt.expiry", "txn.trakt.session"]
    let active = "txn.trakt.active.pointer"
    let cleanup = "txn.trakt.cleanup.marker"
    let candidate = "txn.trakt.candidate.marker"
    let oldPointer = UUID().uuidString.lowercased()
    let oldValues = ["A-access", "A-refresh", "100", "A-session"]
    let newValues = ["B-access", "B-refresh", "200", "B-session"]

    func seed(_ store: MemoryCredentials, pointer: String, values: [String], mirror: Bool = true) {
        for (account, value) in zip(base, values) {
            _ = store.store.write(value, account + ".stage." + pointer)
            if mirror { _ = store.store.write(value, account) }
        }
        _ = store.store.write(pointer, active)
    }

    func durable(_ store: MemoryCredentials, _ account: String) -> String? {
        guard case let .value(value) = store.durableValue(account) else { return nil }
        return value
    }

    func transition(
        _ store: MemoryCredentials,
        values: [String] = newValues
    ) -> CredentialTupleTransitionResult {
        CredentialTupleTransaction.transition(
            baseAccounts: base,
            activePointer: active,
            cleanupMarker: cleanup,
            candidateMarker: candidate,
            candidateValues: values,
            certifiedRead: store.store.certifiedRead,
            recoveryRead: store.store.recoveryRead,
            write: store.store.write
        )
    }

    let exactStore = MemoryCredentials()
    seed(exactStore, pointer: oldPointer, values: oldValues)
    let exactResult = transition(exactStore)
    let exactAuthority: CredentialTupleAuthority?
    if case let .activated(authority) = exactResult {
        exactAuthority = authority
    } else {
        exactAuthority = nil
    }
    let exactStaging = exactAuthority.map { authority in
        authority.pointer != nil
            && CredentialTupleTransaction.canonicalPointer(authority.pointer ?? "") == authority.pointer
            && zip(base, newValues).allSatisfy { account, value in
                durable(exactStore, account + ".stage." + (authority.pointer ?? "")) == value
            }
            && zip(base, newValues).allSatisfy { account, value in durable(exactStore, account) == value }
            && durable(exactStore, candidate) == nil
            && durable(exactStore, cleanup) == nil
    } ?? false

    let candidateStore = MemoryCredentials()
    seed(candidateStore, pointer: oldPointer, values: oldValues)
    candidateStore.failNextWriteAfterPersist(containing: ".active.")
    let candidateResult = transition(candidateStore)
    let candidateClosed = candidateResult == .activationStateUnknown
        && candidateStore.store.certifiedRead(active) == .failure
        && durable(candidateStore, active) != oldPointer
    let candidateRetry = transition(candidateStore)
    let pointerCandidate: Bool
    if case let .activated(authority) = candidateRetry {
        pointerCandidate = candidateClosed
            && authority.values == newValues
            && durable(candidateStore, active) == authority.pointer
            && durable(candidateStore, candidate) == nil
    } else {
        pointerCandidate = false
    }

    let oldStore = MemoryCredentials()
    seed(oldStore, pointer: oldPointer, values: oldValues)
    oldStore.failNextWrite(containing: ".active.")
    let oldResult = transition(oldStore)
    let pointerOld = (oldResult == .failedBeforeActivation)
        && durable(oldStore, active) == oldPointer
        && durable(oldStore, candidate) == nil

    let unknownStore = MemoryCredentials()
    seed(unknownStore, pointer: oldPointer, values: oldValues)
    unknownStore.failNextWriteAfterPersist(containing: ".active.", persistedValue: "not-a-canonical-pointer")
    let unknownResult = transition(unknownStore)
    let pointerUnknown = (unknownResult == .activationStateUnknown)
        && durable(unknownStore, active) == "not-a-canonical-pointer"
        && durable(unknownStore, candidate)?.hasPrefix("candidate:") == true
        && durable(unknownStore, cleanup)?.hasPrefix("pre:") == true

    let retentionStore = MemoryCredentials()
    seed(retentionStore, pointer: oldPointer, values: oldValues)
    retentionStore.failNextWrite(containing: ".active.")
    retentionStore.failNextDelete(containing: ".stage.")
    let retentionResult = transition(retentionStore)
    let candidateAfterFailure = durable(retentionStore, candidate)
    let candidatePointer = candidateAfterFailure.flatMap { raw -> String? in
        guard raw.hasPrefix("candidate:") else { return nil }
        return String(raw.dropFirst("candidate:".count))
    }
    let candidateStageStillPresent = candidatePointer.map { pointer in
        durable(retentionStore, base[0] + ".stage." + pointer) != nil
    } ?? false
    let retentionRetry = transition(retentionStore)
    let candidateRetention = (retentionResult == .cleanupPending(CredentialTupleAuthority(pointer: oldPointer, values: oldValues))
        || candidateAfterFailure != nil)
        && candidateAfterFailure != nil
        && candidateStageStillPresent
        && candidatePointer.map { durable(retentionStore, base[0] + ".stage." + $0) == nil } == true
        && durable(retentionStore, candidate) == nil
        && retentionRetry != .activationStateUnknown

    let legacyStore = MemoryCredentials()
    // Crash shape: active pointer is nil and the legacy mirror is already partial, but the full old tuple
    // exists under oldPointer. Recovery must clean the exact stage before deleting pre:oldPointer.
    for (account, value) in zip(base.dropLast(), oldValues.dropLast()) { _ = legacyStore.store.write(value, account) }
    _ = legacyStore.store.write("pre:legacy:\(oldPointer)", cleanup)
    for (account, value) in zip(base, oldValues) {
        _ = legacyStore.store.write(value, account + ".stage." + oldPointer)
    }
    let legacyResult = transition(legacyStore, values: oldValues)
    let legacyPreRecovery = legacyResult == .failedBeforeActivation
        && durable(legacyStore, cleanup) == nil
        && base.allSatisfy { durable(legacyStore, $0 + ".stage." + oldPointer) == nil }

    let markerGateStore = MemoryCredentials()
    let markerNamespace = CredentialScopeRegistry.shared.currentNamespace()
    let markerBase = [
        TraktTokenSlots.access(markerNamespace),
        TraktTokenSlots.refresh(markerNamespace),
        TraktTokenSlots.expiry(markerNamespace),
        TraktTokenSlots.session(markerNamespace)
    ]
    for (account, value) in zip(markerBase, ["legacy-access", "legacy-refresh", "3600", "legacy-session"]) {
        _ = markerGateStore.store.write(value, account)
    }
    _ = markerGateStore.store.write(UUID().uuidString.lowercased(), TraktTokenSlots.active(markerNamespace))
    let markerAuth = makeAuth(store: markerGateStore)
    let activeMarkerBlocked = await markerAuth.sessionID == nil
        && markerGateStore.value(TraktTokenSlots.session(markerNamespace)) == "legacy-session"

    let cleanupGateStore = MemoryCredentials()
    let cleanupGateAuth = makeAuth(store: cleanupGateStore)
    _ = cleanupGateStore.store.write("legacy-access", TraktTokenSlots.access(markerNamespace))
    _ = cleanupGateStore.store.write("legacy-refresh", TraktTokenSlots.refresh(markerNamespace))
    _ = cleanupGateStore.store.write("3600", TraktTokenSlots.expiry(markerNamespace))
    _ = cleanupGateStore.store.write("pre:existing:\(UUID().uuidString.lowercased())", TraktTokenSlots.cleanup(markerNamespace))
    let cleanupMarkerBlocked = await cleanupGateAuth.sessionID == nil
        && cleanupGateStore.value(TraktTokenSlots.session(markerNamespace)) == nil

    let candidateGateStore = MemoryCredentials()
    let candidateGateAuth = makeAuth(store: candidateGateStore)
    _ = candidateGateStore.store.write("legacy-access", TraktTokenSlots.access(markerNamespace))
    _ = candidateGateStore.store.write("legacy-refresh", TraktTokenSlots.refresh(markerNamespace))
    _ = candidateGateStore.store.write("3600", TraktTokenSlots.expiry(markerNamespace))
    _ = candidateGateStore.store.write("candidate:\(UUID().uuidString.lowercased())", TraktTokenSlots.candidate(markerNamespace))
    let candidateMarkerBlocked = await candidateGateAuth.sessionID == nil
        && candidateGateStore.value(TraktTokenSlots.session(markerNamespace)) == nil
    let repairMarkerGate = activeMarkerBlocked && cleanupMarkerBlocked && candidateMarkerBlocked

    let exactReadStore = MemoryCredentials()
    let exactReadAuth = makeAuth(store: exactReadStore)
    await adoptLiveToken(exactReadAuth, label: "durable")
    let exactNamespace = CredentialScopeRegistry.shared.currentNamespace()
    exactReadStore.injectVolatile("mixed-access", for: TraktTokenSlots.access(exactNamespace))
    exactReadStore.injectVolatile("mixed-session", for: TraktTokenSlots.session(exactNamespace))
    let exactReadSession = await exactReadAuth.sessionID
    let exactReadTokens = await exactReadAuth.syncableTokens()
    let exactReadValidToken = try? await exactReadAuth.validToken()
    let exactDurableReads = exactReadSession?.rawValue != "mixed-session"
        && exactReadTokens?.access == "durable-access"
        && exactReadValidToken == "durable-access"

    let cleanupStore = MemoryCredentials()
    let cleanupAuth = makeAuth(store: cleanupStore)
    await adoptLiveToken(cleanupAuth, label: "A")
    let cleanupNamespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let cleanupOldPointer = durable(cleanupStore, TraktTokenSlots.active(cleanupNamespace)) else {
        return (exactStaging, pointerCandidate, pointerOld, pointerUnknown, candidateRetention, legacyPreRecovery,
                repairMarkerGate, exactDurableReads, false, false, false, false, false)
    }
    let cleanupA = [
        TraktTokenSlots.access(cleanupNamespace),
        TraktTokenSlots.refresh(cleanupNamespace),
        TraktTokenSlots.expiry(cleanupNamespace),
        TraktTokenSlots.session(cleanupNamespace)
    ]
    let cleanupBPointer = UUID().uuidString.lowercased()
    let cleanupBValues = ["B-access", "B-refresh", "200", "B-session"]
    _ = cleanupStore.store.write("candidate:\(cleanupBPointer)", TraktTokenSlots.candidate(cleanupNamespace))
    _ = cleanupStore.store.write("post:\(cleanupOldPointer)", TraktTokenSlots.cleanup(cleanupNamespace))
    for (account, value) in zip(cleanupA, cleanupBValues) {
        _ = cleanupStore.store.write(value, account + ".stage." + cleanupBPointer)
    }
    cleanupStore.failNextDelete(for: cleanupA[0] + ".stage." + cleanupBPointer)
    let cleanupCounter = TraktBoundaryCounter()
    let cleanupKey = "trakt-hostile-signout-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: cleanupKey) { _ in cleanupCounter.increment() }
    let beforeCleanupSignOut = cleanupCounter.snapshot()
    await cleanupAuth.signOut()
    let failedSignOutRetained = cleanupCounter.snapshot() == beforeCleanupSignOut
        && durable(cleanupStore, TraktTokenSlots.active(cleanupNamespace)) == cleanupOldPointer
        && durable(cleanupStore, TraktTokenSlots.candidate(cleanupNamespace)) == "candidate:\(cleanupBPointer)"
        && durable(cleanupStore, TraktTokenSlots.cleanup(cleanupNamespace)) == "post:\(cleanupOldPointer)"
        && durable(cleanupStore, cleanupA[0] + ".stage." + cleanupBPointer) != nil
    await cleanupAuth.signOut()
    let signOutComplete = cleanupA.allSatisfy { durable(cleanupStore, $0) == nil }
        && cleanupA.allSatisfy { durable(cleanupStore, $0 + ".stage." + cleanupOldPointer) == nil }
        && cleanupA.allSatisfy { durable(cleanupStore, $0 + ".stage." + cleanupBPointer) == nil }
        && durable(cleanupStore, TraktTokenSlots.active(cleanupNamespace)) == nil
        && durable(cleanupStore, TraktTokenSlots.candidate(cleanupNamespace)) == nil
        && durable(cleanupStore, TraktTokenSlots.cleanup(cleanupNamespace)) == nil
        && cleanupCounter.snapshot() == beforeCleanupSignOut + 1
    TraktAuthBoundary.removeObserver(key: cleanupKey)
    let signOutRetry = failedSignOutRetained && signOutComplete

    let postCleanupStore = MemoryCredentials()
    let postCleanupAuth = makeAuth(store: postCleanupStore)
    await adoptLiveToken(postCleanupAuth, label: "A")
    let postCleanupNamespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let postOldPointer = durable(postCleanupStore, TraktTokenSlots.active(postCleanupNamespace)) else {
        return (exactStaging, pointerCandidate, pointerOld, pointerUnknown, candidateRetention, legacyPreRecovery,
                repairMarkerGate, exactDurableReads, false, false, signOutRetry, false, false)
    }
    postCleanupStore.failNextDelete(containing: ".stage.\(postOldPointer)")
    let postCleanupCounter = TraktBoundaryCounter()
    let postCleanupKey = "trakt-hostile-post-cleanup-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: postCleanupKey) { _ in postCleanupCounter.increment() }
    let postCleanupBaseline = postCleanupCounter.snapshot()
    let postExpiry = Int(Date().timeIntervalSince1970) + 3_600
    let firstCleanupResult = await postCleanupAuth.adoptTokens(
        access: "B-access", refresh: "B-refresh", expiryUnix: postExpiry)
    let postCleanupFailureSession = await postCleanupAuth.sessionID
    let postCleanupSuppressed = firstCleanupResult == .failure
        && postCleanupCounter.snapshot() == postCleanupBaseline
        && postCleanupFailureSession == nil
    let restartedCleanupAuth = makeAuth(store: postCleanupStore)
    let retryCleanupResult = await restartedCleanupAuth.adoptTokens(
        access: "B-access", refresh: "B-refresh", expiryUnix: postExpiry)
    let retryCleanupTokens = await restartedCleanupAuth.syncableTokens()
    let retryCleanupSession = await restartedCleanupAuth.sessionID
    let postCleanupRetried = retryCleanupResult == .success
        && retryCleanupTokens?.access == "B-access"
        && retryCleanupSession != nil
        && postCleanupCounter.snapshot() == postCleanupBaseline + 1
    TraktAuthBoundary.removeObserver(key: postCleanupKey)
    let postCleanupRetry = postCleanupSuppressed && postCleanupRetried

    let postMirrorStore = MemoryCredentials()
    let postMirrorAuth = makeAuth(store: postMirrorStore)
    await adoptLiveToken(postMirrorAuth, label: "A")
    let postMirrorNamespace = CredentialScopeRegistry.shared.currentNamespace()
    postMirrorStore.failNextWrite(for: TraktTokenSlots.session(postMirrorNamespace))
    let postMirrorCounter = TraktBoundaryCounter()
    let postMirrorKey = "trakt-hostile-post-mirror-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: postMirrorKey) { _ in postMirrorCounter.increment() }
    let postMirrorBaseline = postMirrorCounter.snapshot()
    let mirrorExpiry = Int(Date().timeIntervalSince1970) + 3_600
    let firstMirrorResult = await postMirrorAuth.adoptTokens(
        access: "B-access", refresh: "B-refresh", expiryUnix: mirrorExpiry)
    let postMirrorFailureSession = await postMirrorAuth.sessionID
    let postMirrorSuppressed = firstMirrorResult == .failure
        && postMirrorCounter.snapshot() == postMirrorBaseline
        && postMirrorFailureSession == nil
    let restartedMirrorAuth = makeAuth(store: postMirrorStore)
    let retryMirrorResult = await restartedMirrorAuth.adoptTokens(
        access: "B-access", refresh: "B-refresh", expiryUnix: mirrorExpiry)
    let retryMirrorTokens = await restartedMirrorAuth.syncableTokens()
    let retryMirrorSession = await restartedMirrorAuth.sessionID
    let postMirrorRetried = retryMirrorResult == .success
        && retryMirrorTokens?.access == "B-access"
        && retryMirrorSession != nil
        && postMirrorCounter.snapshot() == postMirrorBaseline + 1
    TraktAuthBoundary.removeObserver(key: postMirrorKey)
    let postMirrorRetry = postMirrorSuppressed && postMirrorRetried

    let malformedStore = MemoryCredentials()
    let malformedAuth = makeAuth(store: malformedStore)
    _ = malformedStore.store.write("not-a-canonical-pointer", TraktTokenSlots.active(exactNamespace))
    let malformedSession = await malformedAuth.sessionID
    let malformedAdoption = await malformedAuth.adoptTokens(access: "B-access", refresh: "B-refresh", expiryUnix: 200)
    let malformedPointerClosed = malformedSession == nil && malformedAdoption == .failure

    let createdAtStore = MemoryCredentials()
    let createdAtAuth = makeAuth(store: createdAtStore)
    await adoptLiveToken(createdAtAuth, label: "A")
    let createdAtNamespace = CredentialScopeRegistry.shared.currentNamespace()
    _ = createdAtStore.store.write(nil, TraktTokenSlots.createdAt(createdAtNamespace))
    createdAtStore.failNextWrite(for: TraktTokenSlots.createdAt(createdAtNamespace))
    let createdAtResult = await createdAtAuth.adoptTokens(
        access: "B-access", refresh: "B-refresh", expiryUnix: Int(Date().timeIntervalSince1970) + 3_600)
    let createdAtTokens = await createdAtAuth.syncableTokens()
    let createdAtSession = await createdAtAuth.sessionID
    let createdAtValidToken = try? await createdAtAuth.validToken()
    let createdAtBestEffort = createdAtResult == .success
        && createdAtTokens?.access == "B-access"
        && createdAtSession != nil
        && createdAtValidToken == "B-access"

    return (
        exactStaging,
        pointerCandidate,
        pointerOld,
        pointerUnknown,
        candidateRetention,
        legacyPreRecovery,
        repairMarkerGate,
        exactDurableReads,
        postCleanupRetry,
        postMirrorRetry,
        signOutRetry,
        malformedPointerClosed,
        createdAtBestEffort
    )
}

private func testTraktPublicRetryRecoversActivePointer() async -> (
    publicRetry: Bool,
    malformedClosed: Bool,
    mismatchedClosed: Bool
) {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await adoptLiveToken(auth, label: "A")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = TraktTokenSlots.active(namespace)
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let recorder = TraktPublicationRecorder()
    let observerKey = "trakt-public-retry-pointer-recovery-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observerKey) { recorder.append($0) }

    let expiry = Int(Date().timeIntervalSince1970) + 3_600
    store.failNextWriteAfterPersist(containing: ".active.")
    let first = await auth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let rawPointer: String? = {
        guard case let .value(raw) = store.durableValue(active) else { return nil }
        return raw
    }()
    let firstSuppressed = first == .failure
        && store.store.certifiedRead(active) == .failure
        && rawPointer != nil
        && recorder.snapshot().isEmpty

    let restarted = makeAuth(store: store)
    let retry = await restarted.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let selected = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: store.store.certifiedRead
    )
    let exactCertifiedTuple: Bool = {
        guard case let .authority(authority) = selected,
              authority.values == ["B-access", "B-refresh", String(expiry), authority.values.last ?? ""],
              let pointer = rawPointer,
              store.store.certifiedRead(active) == .value(pointer) else { return false }
        return !pointer.isEmpty && authority.values.last?.isEmpty == false
    }()
    let publicRetry = firstSuppressed
        && retry == .success
        && exactCertifiedTuple
        && recorder.snapshot().count == 1
    TraktAuthBoundary.removeObserver(key: observerKey)

    let malformedStore = MemoryCredentials()
    let malformedAuth = makeAuth(store: malformedStore)
    await adoptLiveToken(malformedAuth, label: "A")
    let malformedActive = TraktTokenSlots.active(namespace)
    let malformedRecorder = TraktPublicationRecorder()
    let malformedObserver = "trakt-public-retry-malformed-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: malformedObserver) { malformedRecorder.append($0) }
    malformedStore.failNextWriteAfterPersist(
        containing: ".active.",
        persistedValue: "not-a-canonical-pointer"
    )
    let malformedFirst = await malformedAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let malformedRetryAuth = makeAuth(store: malformedStore)
    let malformedRetry = await malformedRetryAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let malformedClosed = malformedFirst == .failure
        && malformedRetry == .failure
        && malformedStore.store.certifiedRead(malformedActive) == .failure
        && malformedStore.durableValue(malformedActive) == .value("not-a-canonical-pointer")
        && malformedRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: malformedObserver)

    let mismatchedStore = MemoryCredentials()
    let mismatchedAuth = makeAuth(store: mismatchedStore)
    await adoptLiveToken(mismatchedAuth, label: "A")
    let mismatchedActive = TraktTokenSlots.active(namespace)
    let mismatchedPointer = UUID().uuidString.lowercased()
    let mismatchedRecorder = TraktPublicationRecorder()
    let mismatchedObserver = "trakt-public-retry-mismatched-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: mismatchedObserver) { mismatchedRecorder.append($0) }
    mismatchedStore.failNextWriteAfterPersist(
        containing: ".active.",
        persistedValue: mismatchedPointer
    )
    let mismatchedFirst = await mismatchedAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let mismatchedRetryAuth = makeAuth(store: mismatchedStore)
    let mismatchedRetry = await mismatchedRetryAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let mismatchedAuthority = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: mismatchedActive,
        certifiedRead: mismatchedStore.store.certifiedRead
    )
    let mismatchedClosed = mismatchedFirst == .failure
        && mismatchedRetry == .failure
        && mismatchedStore.store.certifiedRead(mismatchedActive) == .value(mismatchedPointer)
        && mismatchedAuthority == .failure
        && mismatchedRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: mismatchedObserver)
    return (publicRetry, malformedClosed, mismatchedClosed)
}

private func testTraktRefreshPersistencePointerRecovery() async -> (
    rotatedRecovered: Bool,
    malformedClosed: Bool,
    unbackedClosed: Bool
) {
    let now = Int(Date().timeIntervalSince1970)
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = TraktTokenSlots.active(namespace)
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let rotatedExpiry = now + 3_600
    let rotatedJSON = """
    {
      "status": "ok",
      "token": {
        "access_token": "rotated-access",
        "refresh_token": "rotated-refresh",
        "expires_in": 3600,
        "token_type": "bearer",
        "created_at": \(now)
      }
    }
    """

    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await auth.adoptTokens(access: "old-access", refresh: "old-refresh", expiryUnix: now - 10)
    guard let beforeSession = await auth.sessionID else {
        return (false, false, false)
    }
    let recorder = TraktPublicationRecorder()
    let observer = "trakt-refresh-pointer-recovery-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    FixtureURLProtocol.fixture.set(status: 200, json: rotatedJSON)
    store.failNextWriteAfterPersist(containing: ".active.")
    let first = try? await auth.validToken()
    let rawPointer: String? = {
        guard case let .value(raw) = store.durableValue(active) else { return nil }
        return raw
    }()
    let firstSuppressed = first == nil
        && store.store.certifiedRead(active) == .failure
        && rawPointer != nil
        && recorder.snapshot().isEmpty

    FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"invalid_grant"}"#)
    let retry = try? await auth.validToken()
    let retrySession = await auth.sessionID
    let retryTokens = await auth.syncableTokens()
    let selected = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: store.store.certifiedRead
    )
    let exactRotatedTuple: Bool = {
        guard case let .authority(authority) = selected,
              authority.values.count == 4,
              authority.values[0] == "rotated-access",
              authority.values[1] == "rotated-refresh",
              authority.values[2] == String(rotatedExpiry),
              !authority.values[3].isEmpty,
              let pointer = rawPointer,
              store.store.certifiedRead(active) == .value(pointer) else { return false }
        return !pointer.isEmpty
    }()
    let rotatedRecovered = firstSuppressed
        && retry == "rotated-access"
        && exactRotatedTuple
        && retrySession == beforeSession
        && retryTokens?.refresh == "rotated-refresh"
        && recorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: observer)

    let malformedStore = MemoryCredentials()
    let malformedAuth = makeAuth(store: malformedStore)
    await malformedAuth.adoptTokens(access: "old-access", refresh: "old-refresh", expiryUnix: now - 10)
    let malformedRecorder = TraktPublicationRecorder()
    let malformedObserver = "trakt-refresh-malformed-pointer-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: malformedObserver) { malformedRecorder.append($0) }
    FixtureURLProtocol.fixture.set(status: 200, json: rotatedJSON)
    malformedStore.failNextWriteAfterPersist(
        containing: ".active.",
        persistedValue: "not-a-canonical-pointer"
    )
    let malformedFirst = try? await malformedAuth.validToken()
    let malformedRetry = try? await malformedAuth.validToken()
    let malformedClosed = malformedFirst == nil
        && malformedRetry == nil
        && malformedStore.store.certifiedRead(active) == .failure
        && malformedStore.durableValue(active) == .value("not-a-canonical-pointer")
        && malformedRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: malformedObserver)

    let unbackedStore = MemoryCredentials()
    let unbackedAuth = makeAuth(store: unbackedStore)
    await unbackedAuth.adoptTokens(access: "old-access", refresh: "old-refresh", expiryUnix: now - 10)
    let unbackedPointer = UUID().uuidString.lowercased()
    let unbackedRecorder = TraktPublicationRecorder()
    let unbackedObserver = "trakt-refresh-unbacked-pointer-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: unbackedObserver) { unbackedRecorder.append($0) }
    FixtureURLProtocol.fixture.set(status: 200, json: rotatedJSON)
    unbackedStore.failNextWriteAfterPersist(
        containing: ".active.",
        persistedValue: unbackedPointer
    )
    let unbackedFirst = try? await unbackedAuth.validToken()
    let unbackedRetry = try? await unbackedAuth.validToken()
    let unbackedAuthority = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: unbackedStore.store.certifiedRead
    )
    let unbackedClosed = unbackedFirst == nil
        && unbackedRetry == nil
        && unbackedStore.store.certifiedRead(active) == .value(unbackedPointer)
        && unbackedAuthority == .failure
        && unbackedRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: unbackedObserver)
    FixtureURLProtocol.fixture.set(status: 200)
    return (rotatedRecovered, malformedClosed, unbackedClosed)
}

private func testTraktCandidateStageFailAfterPersistRecovery() async -> (
    allSlotsRecovered: Bool,
    mismatchedClosed: Bool,
    unbackedClosed: Bool,
    rotatedRefreshRecovered: Bool
) {
    let base = [
        "stage-recovery.trakt.access",
        "stage-recovery.trakt.refresh",
        "stage-recovery.trakt.expiry",
        "stage-recovery.trakt.session"
    ]
    let active = "stage-recovery.trakt.active"
    let cleanup = "stage-recovery.trakt.cleanup"
    let candidate = "stage-recovery.trakt.candidate"
    let oldPointer = UUID().uuidString.lowercased()
    let candidatePointer = UUID().uuidString.lowercased()
    let oldValues = ["A-access", "A-refresh", "100", "A-session"]
    let candidateValues = ["B-access", "B-refresh", "200", "B-session"]

    func transition(_ store: MemoryCredentials) -> CredentialTupleTransitionResult {
        CredentialTupleTransaction.transition(
            baseAccounts: base,
            activePointer: active,
            cleanupMarker: cleanup,
            candidateMarker: candidate,
            candidateValues: candidateValues,
            certifiedRead: store.store.certifiedRead,
            recoveryRead: store.store.recoveryRead,
            write: store.store.write
        )
    }

    func authority(_ store: MemoryCredentials) -> CredentialTupleReadResult {
        CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: store.store.certifiedRead
        )
    }

    var allSlotsRecovered = true
    for failingIndex in base.indices {
        let store = MemoryCredentials()
        for (account, value) in zip(base, oldValues) {
            _ = store.store.write(value, account + ".stage." + oldPointer)
        }
        _ = store.store.write(oldPointer, active)
        _ = store.store.write("candidate:\(candidatePointer)", candidate)
        let candidateWasCertified = store.store.certifiedRead(candidate) == .value("candidate:\(candidatePointer)")

        for (index, account) in base.enumerated() {
            let stage = account + ".stage." + candidatePointer
            if index == failingIndex {
                store.failNextWriteAfterPersist(containing: stage)
            }
            _ = store.store.write(candidateValues[index], stage)
        }
        let failedStage = base[failingIndex] + ".stage." + candidatePointer
        let failAfterPersistEvidence = store.store.certifiedRead(failedStage) == .failure
            && store.durableValue(failedStage) == .value(candidateValues[failingIndex])

        let first = transition(store)
        let retry = transition(store)
        let completed = first == .activated(authorityValue(store: store, active: active, values: candidateValues))
            || retry == .activated(authorityValue(store: store, active: active, values: candidateValues))
        let selectedExact = authority(store) == .authority(
            CredentialTupleAuthority(pointer: authorityPointer(store, active: active), values: candidateValues)
        )
        let candidateRemoved = store.store.certifiedRead(candidate) == .missing
        allSlotsRecovered = allSlotsRecovered
            && candidateWasCertified
            && failAfterPersistEvidence
            && completed
            && selectedExact
            && candidateRemoved
    }

    let mismatchedStore = MemoryCredentials()
    for (account, value) in zip(base, oldValues) {
        _ = mismatchedStore.store.write(value, account + ".stage." + oldPointer)
    }
    _ = mismatchedStore.store.write(oldPointer, active)
    _ = mismatchedStore.store.write("candidate:\(candidatePointer)", candidate)
    for (index, account) in base.enumerated() {
        let stage = account + ".stage." + candidatePointer
        if index == 0 {
            mismatchedStore.failNextWriteAfterPersist(
                containing: stage,
                persistedValue: "mismatched-stage-value"
            )
        }
        _ = mismatchedStore.store.write(candidateValues[index], stage)
    }
    let mismatchedResult = transition(mismatchedStore)
    let mismatchedClosed = mismatchedResult == .activationStateUnknown
        && mismatchedStore.store.certifiedRead(active) == .value(oldPointer)
        && mismatchedStore.store.certifiedRead(candidate) == .value("candidate:\(candidatePointer)")
        && mismatchedStore.store.certifiedRead(base[0] + ".stage." + candidatePointer) == .failure
        && mismatchedStore.durableValue(base[0] + ".stage." + candidatePointer) == .value("mismatched-stage-value")
        && authority(mismatchedStore) != .authority(
            CredentialTupleAuthority(pointer: authorityPointer(mismatchedStore, active: active), values: candidateValues)
        )

    let unbackedStore = MemoryCredentials()
    for (account, value) in zip(base, oldValues) {
        _ = unbackedStore.store.write(value, account + ".stage." + oldPointer)
    }
    _ = unbackedStore.store.write(oldPointer, active)
    _ = unbackedStore.store.write("candidate:\(candidatePointer)", candidate)
    for (index, account) in base.enumerated() {
        let stage = account + ".stage." + candidatePointer
        if index == 0 {
            unbackedStore.failNextWriteAfterPersistMissing(containing: stage)
        }
        _ = unbackedStore.store.write(candidateValues[index], stage)
    }
    let unbackedResult = transition(unbackedStore)
    let unbackedClosed: Bool = {
        guard case let .activated(authority) = unbackedResult,
              authority.values == candidateValues,
              authority.pointer != oldPointer,
              authority.pointer != candidatePointer else { return false }
        return unbackedStore.store.certifiedRead(candidate) == .missing
            && unbackedStore.store.certifiedRead(base[0] + ".stage." + candidatePointer) == .missing
            && unbackedStore.durableValue(base[0] + ".stage." + candidatePointer) == .missing
            && CredentialTupleTransaction.readAuthority(
                baseAccounts: base,
                activePointer: active,
                certifiedRead: unbackedStore.store.certifiedRead
            ) == .authority(authority)
    }()

    let now = Int(Date().timeIntervalSince1970)
    let rotatedJSON = """
    {
      "status": "ok",
      "token": {
        "access_token": "rotated-stage-access",
        "refresh_token": "rotated-stage-refresh",
        "expires_in": 3600,
        "token_type": "bearer",
        "created_at": \(now)
      }
    }
    """
    let refreshStore = MemoryCredentials()
    let refreshAuth = makeAuth(store: refreshStore)
    await refreshAuth.adoptTokens(access: "spent-access", refresh: "spent-refresh", expiryUnix: now - 10)
    FixtureURLProtocol.fixture.set(status: 200, json: rotatedJSON)
    refreshStore.failNextWriteAfterPersist(containing: ".stage.")
    let firstRefresh = try? await refreshAuth.validToken()
    let firstRefreshSuppressed = firstRefresh == nil
    FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"invalid_grant"}"#)
    let recoveredRefresh = try? await refreshAuth.validToken()
    let refreshTokens = await refreshAuth.syncableTokens()
    let refreshAuthority = CredentialTupleTransaction.readAuthority(
        baseAccounts: [
            TraktTokenSlots.access(CredentialScopeRegistry.shared.currentNamespace()),
            TraktTokenSlots.refresh(CredentialScopeRegistry.shared.currentNamespace()),
            TraktTokenSlots.expiry(CredentialScopeRegistry.shared.currentNamespace()),
            TraktTokenSlots.session(CredentialScopeRegistry.shared.currentNamespace())
        ],
        activePointer: TraktTokenSlots.active(CredentialScopeRegistry.shared.currentNamespace()),
        certifiedRead: refreshStore.store.certifiedRead
    )
    let rotatedRefreshRecovered = firstRefreshSuppressed
        && recoveredRefresh == "rotated-stage-access"
        && refreshTokens?.refresh == "rotated-stage-refresh"
        && refreshAuthority != .failure
        && refreshAuthority != .none
    FixtureURLProtocol.fixture.set(status: 200)

    return (allSlotsRecovered, mismatchedClosed, unbackedClosed, rotatedRefreshRecovered)
}

private func testTraktEmptyCandidateStageFailAfterPersistRecovery() async -> (
    allSlotsRecovered: Bool,
    malformedClosed: Bool,
    unbackedClosed: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let active = TraktTokenSlots.active(namespace)
    let candidate = TraktTokenSlots.candidate(namespace)
    let expiry = Int(Date().timeIntervalSince1970) + 3_600
    let requested = ["first-login-access", "first-login-refresh", String(expiry)]

    var allSlotsRecovered = true
    for failingIndex in base.indices {
        let store = MemoryCredentials()
        let auth = makeAuth(store: store)
        let recorder = TraktPublicationRecorder()
        let observer = "trakt-empty-candidate-\(failingIndex)-\(UUID().uuidString)"
        TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
        store.failNextWriteAfterPersist(containing: base[failingIndex] + ".stage.")

        let first = await auth.adoptTokens(
            access: requested[0],
            refresh: requested[1],
            expiryUnix: expiry
        )
        let candidateRaw: String?
        if case let .value(raw) = store.store.certifiedRead(candidate),
           raw.hasPrefix("candidate:") {
            candidateRaw = raw
        } else {
            candidateRaw = nil
        }
        let candidatePointer = candidateRaw.map { String($0.dropFirst("candidate:".count)) }
        let failedStage = candidatePointer.map { base[failingIndex] + ".stage." + $0 }
        let persistedStageValue: Bool = failedStage.map {
            guard case let .value(value) = store.durableValue($0) else { return false }
            return !value.isEmpty
        } ?? false
        let failAfterPersistEvidence = first == .failure
            && candidateRaw != nil
            && failedStage.map { store.store.certifiedRead($0) == .failure } == true
            && persistedStageValue

        let retry = await auth.adoptTokens(
            access: requested[0],
            refresh: requested[1],
            expiryUnix: expiry
        )
        let authority = CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: store.store.certifiedRead
        )
        var exactAuthority = false
        var finalSession: String?
        var finalPointer: String?
        if case let .authority(value) = authority,
           value.values.count == 4,
           value.values[0] == requested[0],
           value.values[1] == requested[1],
           value.values[2] == requested[2],
           !value.values[3].isEmpty {
            exactAuthority = true
            finalSession = value.values[3]
            finalPointer = value.pointer
        }
        let candidateResolved = candidatePointer.map { pointer in
            if finalPointer == pointer, let finalSession {
                let expected = [requested[0], requested[1], requested[2], finalSession]
                return zip(base, expected).allSatisfy {
                    store.store.certifiedRead($0.0 + ".stage." + pointer) == .value($0.1)
                }
            }
            return base.allSatisfy { store.store.certifiedRead($0 + ".stage." + pointer) == .missing }
        } ?? false
        let publicationExact = finalSession.map { recorder.snapshot() == [$0] } ?? false
        allSlotsRecovered = allSlotsRecovered
            && failAfterPersistEvidence
            && retry == .success
            && exactAuthority
            && finalPointer.map { store.store.certifiedRead(active) == .value($0) } == true
            && store.store.certifiedRead(candidate) == .missing
            && candidateResolved
            && publicationExact
        TraktAuthBoundary.removeObserver(key: observer)
    }

    let malformedStore = MemoryCredentials()
    let malformedAuth = makeAuth(store: malformedStore)
    let malformedRecorder = TraktPublicationRecorder()
    let malformedObserver = "trakt-empty-malformed-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: malformedObserver) { malformedRecorder.append($0) }
    malformedStore.failNextWriteAfterPersist(
        containing: base[0] + ".stage.",
        persistedValue: "mismatched-first-login-access"
    )
    let malformedFirst = await malformedAuth.adoptTokens(
        access: requested[0],
        refresh: requested[1],
        expiryUnix: expiry
    )
    let malformedCandidate = malformedStore.value(candidate)
    malformedStore.failNextDelete(containing: base[0] + ".stage.")
    let malformedRetry = await malformedAuth.adoptTokens(
        access: requested[0],
        refresh: requested[1],
        expiryUnix: expiry
    )
    let malformedClosed = malformedFirst == .failure
        && malformedRetry == .failure
        && malformedCandidate != nil
        && malformedStore.store.certifiedRead(active) == .missing
        && malformedCandidate.map { malformedStore.store.certifiedRead(candidate) == .value($0) } == true
        && malformedRecorder.snapshot().isEmpty
        && CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: malformedStore.store.certifiedRead
        ) == .none
    TraktAuthBoundary.removeObserver(key: malformedObserver)

    let unbackedStore = MemoryCredentials()
    let unbackedAuth = makeAuth(store: unbackedStore)
    let unbackedRecorder = TraktPublicationRecorder()
    let unbackedObserver = "trakt-empty-unbacked-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: unbackedObserver) { unbackedRecorder.append($0) }
    unbackedStore.failNextWriteAfterPersistMissing(containing: base[0] + ".stage.")
    let unbackedFirst = await unbackedAuth.adoptTokens(
        access: requested[0],
        refresh: requested[1],
        expiryUnix: expiry
    )
    let unbackedCandidate = unbackedStore.value(candidate)
    let unbackedPointer = unbackedCandidate.map { String($0.dropFirst("candidate:".count)) }
    let unbackedStage = unbackedPointer.map { base[0] + ".stage." + $0 }
    unbackedStore.failNextDelete(containing: base[0] + ".stage.")
    let unbackedRetry = await unbackedAuth.adoptTokens(
        access: requested[0],
        refresh: requested[1],
        expiryUnix: expiry
    )
    let unbackedClosed = unbackedFirst == .failure
        && unbackedRetry == .failure
        && unbackedCandidate != nil
        && unbackedStore.store.certifiedRead(active) == .missing
        && unbackedCandidate.map { unbackedStore.store.certifiedRead(candidate) == .value($0) } == true
        && unbackedStage.map {
            unbackedStore.store.certifiedRead($0) == .failure
                && unbackedStore.durableValue($0) == .missing
        } == true
        && unbackedRecorder.snapshot().isEmpty
        && CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: unbackedStore.store.certifiedRead
        ) == .none
    TraktAuthBoundary.removeObserver(key: unbackedObserver)

    return (allSlotsRecovered, malformedClosed, unbackedClosed)
}

private func testTraktMutationRecoveryPublicationGate() async -> (
    activeMissingClosed: Bool,
    activeCandidateClosed: Bool,
    sameSessionRefreshRecovered: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = TraktTokenSlots.active(namespace)
    let candidate = TraktTokenSlots.candidate(namespace)
    let publication = TraktTokenSlots.publication(namespace)
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let expiry = Int(Date().timeIntervalSince1970) + 3_600

    let activeMissingStore = MemoryCredentials()
    let activeMissingAuth = makeAuth(store: activeMissingStore)
    activeMissingStore.failNextWriteAfterPersist(containing: ".stage.")
    let activeMissingAdoption = await activeMissingAuth.adoptTokens(
        access: "missing-access",
        refresh: "missing-refresh",
        expiryUnix: expiry
    )
    let activeMissingCandidate = activeMissingStore.value(candidate)
    let activeMissingRecorder = TraktPublicationRecorder()
    let activeMissingObserver = "trakt-mutation-gate-missing-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: activeMissingObserver) { activeMissingRecorder.append($0) }
    let activeMissingToken = try? await activeMissingAuth.validToken()
    let activeMissingClosed = activeMissingAdoption == .failure
        && activeMissingToken == nil
        && activeMissingStore.store.certifiedRead(active) == .missing
        && activeMissingCandidate != nil
        && activeMissingCandidate.map { activeMissingStore.store.certifiedRead(candidate) == .value($0) } == true
        && activeMissingStore.store.certifiedRead(publication) == .missing
        && activeMissingRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: activeMissingObserver)

    let activeCandidateStore = MemoryCredentials()
    let activeCandidateAuth = makeAuth(store: activeCandidateStore)
    await adoptLiveToken(activeCandidateAuth, label: "gate-A")
    guard let sessionA = await activeCandidateAuth.sessionID,
          let activePointerA = activeCandidateStore.value(active) else {
        return (activeMissingClosed, false, false)
    }
    let activeCandidateRecorder = TraktPublicationRecorder()
    let activeCandidateObserver = "trakt-mutation-gate-active-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: activeCandidateObserver) { activeCandidateRecorder.append($0) }
    activeCandidateStore.failNextWriteAfterPersist(containing: ".stage.")
    let activeCandidateAdoption = await activeCandidateAuth.adoptTokens(
        access: "candidate-access",
        refresh: "candidate-refresh",
        expiryUnix: expiry
    )
    let activeCandidateRaw = activeCandidateStore.value(candidate)
    let activeCandidateToken = try? await activeCandidateAuth.validToken()
    let activeCandidateBoundToken = try? await activeCandidateAuth.validToken(for: sessionA)
    let activeCandidateClosed = activeCandidateAdoption == .failure
        && activeCandidateToken == nil
        && activeCandidateBoundToken == nil
        && activeCandidateStore.store.certifiedRead(active) == .value(activePointerA)
        && activeCandidateRaw != nil
        && activeCandidateRaw.map { activeCandidateStore.store.certifiedRead(candidate) == .value($0) } == true
        && activeCandidateStore.store.certifiedRead(publication) == .missing
        && activeCandidateRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: activeCandidateObserver)

    let refreshStore = MemoryCredentials()
    let refreshAuth = makeAuth(store: refreshStore)
    let now = Int(Date().timeIntervalSince1970)
    await refreshAuth.adoptTokens(
        access: "same-session-access",
        refresh: "same-session-refresh",
        expiryUnix: now - 10
    )
    guard let refreshSessionA = await refreshAuth.sessionID else {
        return (activeMissingClosed, activeCandidateClosed, false)
    }
    let refreshRecorder = TraktPublicationRecorder()
    let refreshObserver = "trakt-mutation-gate-refresh-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: refreshObserver) { refreshRecorder.append($0) }
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {
          "status": "ok",
          "token": {
            "access_token": "same-session-rotated-access",
            "refresh_token": "same-session-rotated-refresh",
            "expires_in": 3600,
            "token_type": "bearer",
            "created_at": \(now)
          }
        }
        """
    )
    refreshStore.failNextWriteAfterPersist(containing: ".stage.")
    let firstRefresh = try? await refreshAuth.validToken()
    let recoveredRefresh = try? await refreshAuth.validToken()
    let refreshAuthority = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: refreshStore.store.certifiedRead
    )
    let sameSessionRefreshRecovered: Bool = {
        guard firstRefresh == nil,
              recoveredRefresh == "same-session-rotated-access",
              refreshRecorder.snapshot().isEmpty,
              case let .authority(authority) = refreshAuthority,
              authority.values.count == 4,
              authority.values[0] == "same-session-rotated-access",
              authority.values[1] == "same-session-rotated-refresh",
              Int(authority.values[2]) != nil,
              authority.values[3] == refreshSessionA.rawValue else { return false }
        return true
    }()
    FixtureURLProtocol.fixture.set(status: 200)
    TraktAuthBoundary.removeObserver(key: refreshObserver)

    return (activeMissingClosed, activeCandidateClosed, sameSessionRefreshRecovered)
}

private func testTraktPublicRetryAfterCandidatePersistenceFailures() async -> (
    activePointer: Bool,
    cleanupStage: Bool,
    cleanupMarker: Bool,
    mirror: Bool,
    missingIntentClosed: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = TraktTokenSlots.active(namespace)
    let publication = TraktTokenSlots.publication(namespace)
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let expiry = Int(Date().timeIntervalSince1970) + 3_600

    func exercise(
        label: String,
        arm: (MemoryCredentials, [String], String) -> Void
    ) async -> Bool {
        let store = MemoryCredentials()
        let auth = makeAuth(store: store)
        await adoptLiveToken(auth, label: "\(label)-A")
        guard let sessionA = await auth.sessionID,
              let oldPointer = store.value(active) else { return false }
        let recorder = TraktPublicationRecorder()
        let observer = "trakt-public-retry-\(label)-\(UUID().uuidString)"
        TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
        arm(store, base, oldPointer)
        let first = await auth.adoptTokens(
            access: "\(label)-B-access",
            refresh: "\(label)-B-refresh",
            expiryUnix: expiry
        )
        let firstSuppressed = first == .failure && recorder.snapshot().isEmpty
        let sessionBoundRetry = try? await auth.validToken(for: sessionA)
        let publicRetry = try? await auth.validToken()
        let authority = CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: store.store.certifiedRead
        )
        let exactB: Bool = {
            guard case let .authority(selected) = authority,
                  selected.values.count == 4,
                  selected.values[0] == "\(label)-B-access",
                  selected.values[1] == "\(label)-B-refresh",
                  selected.values[2] == String(expiry),
                  !selected.values[3].isEmpty else { return false }
            return publicRetry == "\(label)-B-access"
                && sessionBoundRetry == nil
                && recorder.snapshot() == [selected.values[3]]
                && store.store.certifiedRead(publication) == .missing
        }()
        TraktAuthBoundary.removeObserver(key: observer)
        return firstSuppressed && exactB
    }

    let activePointer = await exercise(label: "active-pointer") { store, _, _ in
        store.failNextWriteAfterPersist(containing: ".active.")
    }
    let cleanupStage = await exercise(label: "cleanup-stage") { store, base, oldPointer in
        store.failNextWriteAfterPersist(containing: base[0] + ".stage." + oldPointer)
    }
    let cleanupMarker = await exercise(label: "cleanup-marker") { store, _, _ in
        store.failWriteAfterPersistOnMatchingWrite(3, containing: ".cleanup.")
    }
    let mirror = await exercise(label: "mirror") { store, base, _ in
        for account in base {
            _ = store.store.write(nil, account)
        }
        // The tuple manifest and access.stage.<candidate> are the first two matches; the mirror is third.
        store.failWriteAfterPersistOnMatchingWrite(3, containing: base[0])
    }

    let missingStore = MemoryCredentials()
    let missingAuth = makeAuth(store: missingStore)
    await adoptLiveToken(missingAuth, label: "missing-A")
    guard let missingSessionA = await missingAuth.sessionID else {
        return (activePointer, cleanupStage, cleanupMarker, mirror, false)
    }
    missingStore.failNextWriteAfterPersist(containing: ".active.")
    let missingFirst = await missingAuth.adoptTokens(
        access: "missing-B-access",
        refresh: "missing-B-refresh",
        expiryUnix: expiry
    )
    _ = missingStore.store.write(nil, publication)
    let missingRecorder = TraktPublicationRecorder()
    let missingObserver = "trakt-public-retry-missing-intent-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: missingObserver) { missingRecorder.append($0) }
    let missingBoundRetry = try? await missingAuth.validToken(for: missingSessionA)
    let missingPublicRetry = try? await missingAuth.validToken()
    let missingIntentClosed = missingFirst == .failure
        && missingBoundRetry == nil
        && missingPublicRetry == nil
        && missingRecorder.snapshot().isEmpty
        && missingStore.store.certifiedRead(publication) == .missing
        && missingStore.store.certifiedRead(TraktTokenSlots.candidate(namespace)) != .missing
    TraktAuthBoundary.removeObserver(key: missingObserver)
    return (activePointer, cleanupStage, cleanupMarker, mirror, missingIntentClosed)
}

private func testTraktPublicationBoundaryRaces() async -> (
    signOutOrdered: Bool,
    ownerSwitchOrdered: Bool
) {
    let signOutStore = MemoryCredentials()
    let signOutAuth = makeAuth(store: signOutStore)
    await adoptLiveToken(signOutAuth, label: "race-signout")
    guard let signOutSession = await signOutAuth.sessionID else { return (false, false) }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let signOutPublication = TraktTokenSlots.publication(namespace)
    _ = signOutStore.store.write("pending:\(signOutSession.rawValue)", signOutPublication)
    let signOutOrder = TraktBlockingPublicationOrder()
    let signOutReentry = TraktBoundaryAcquisitionBox()
    let signOutObserver = "trakt-publication-boundary-signout-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: signOutObserver) {
        signOutReentry.record(CredentialPublicationOutbox.acquireBoundary())
        signOutOrder.observe($0)
    }
    let signOutDrainer = Task.detached { try? await signOutAuth.validToken() }
    let signOutEntered = signOutOrder.waitForEntry()
    let signOutTask = Task { await signOutAuth.signOut() }
    signOutOrder.releaseCallback()
    _ = await signOutDrainer.value
    let signOutCompleted = await signOutTask.value
    let signOutEvents = signOutOrder.snapshot()
    let signOutOrdered = signOutEntered
        && signOutReentry.snapshot() == .reentrant
        && signOutCompleted
        && signOutEvents == [signOutSession.rawValue, "nil"]
        && signOutStore.store.certifiedRead(TraktTokenSlots.active(namespace)) == .missing
    TraktAuthBoundary.removeObserver(key: signOutObserver)

    let accountA = CredentialScope(canonicalRemoteAccountID: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountA) }
    let ownerStore = MemoryCredentials()
    let ownerAuth = makeAuth(store: ownerStore)
    await adoptLiveToken(ownerAuth, label: "race-owner")
    guard let ownerSession = await ownerAuth.sessionID else { return (signOutOrdered, false) }
    let ownerNamespace = accountA.storageNamespace
    let ownerPublication = TraktTokenSlots.publication(ownerNamespace)
    _ = ownerStore.store.write("pending:\(ownerSession.rawValue)", ownerPublication)
    let ownerOrder = TraktBlockingPublicationOrder()
    let ownerObserver = "trakt-publication-boundary-owner-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: ownerObserver) { ownerOrder.observe($0) }
    let ownerDrainer = Task.detached { try? await ownerAuth.validToken() }
    let ownerEntered = ownerOrder.waitForEntry()
    let beforeRejectedBind = await MainActor.run { CredentialScopeRegistry.shared.capture() }
    let rejectedTryBind = await MainActor.run { CredentialScopeRegistry.shared.tryBind(accountB) }
    let rejectedBind = await MainActor.run { CredentialScopeRegistry.shared.bind(accountB) }
    let captureAfterRejectedBind = await MainActor.run { CredentialScopeRegistry.shared.capture() }
    let rejectedWithoutFlip = rejectedTryBind == nil
        && rejectedBind == beforeRejectedBind
        && captureAfterRejectedBind == beforeRejectedBind
    ownerOrder.releaseCallback()
    _ = await ownerDrainer.value
    let acceptedBind = await MainActor.run { CredentialScopeRegistry.shared.bind(accountB) }
    let captureAfterAcceptedBind = await MainActor.run { CredentialScopeRegistry.shared.capture() }
    let ownerSwitchOrdered = ownerEntered
        && rejectedWithoutFlip
        && acceptedBind.scope == accountB
        && captureAfterAcceptedBind == acceptedBind
    TraktAuthBoundary.removeObserver(key: ownerObserver)

    // A queued boundary is resumed after the current lease releases without blocking MainActor progress.
    guard CredentialPublicationOutbox.acquireBoundary() == .acquired else {
        await MainActor.run { _ = CredentialScopeRegistry.shared.bind(.signedOutDevice) }
        return (signOutOrdered, false)
    }
    let queuedBoundary = Task { await CredentialPublicationOutbox.waitForBoundary() }
    let mainActorStayedLive = await MainActor.run { CredentialScopeRegistry.shared.capture().scope == accountB }
    CredentialPublicationOutbox.endBoundary()
    let queuedAcquired = await queuedBoundary.value == .acquired
    if queuedAcquired { CredentialPublicationOutbox.endBoundary() }
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(.signedOutDevice) }
    let ownerResult = ownerSwitchOrdered && mainActorStayedLive && queuedAcquired
    return (signOutOrdered, ownerResult)
}

private func testTraktCrossInstanceClearWaitsForDispatch() async -> Bool {
    let store = MemoryCredentials()
    let drainer = makeAuth(store: store)
    let clearer = makeAuth(store: store)
    await adoptLiveToken(drainer, label: "cross-instance-clear")
    guard let session = await drainer.sessionID else { return false }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = TraktTokenSlots.active(namespace)
    let publication = TraktTokenSlots.publication(namespace)
    _ = store.store.write("pending:\(session.rawValue)", publication)

    let order = TraktBlockingPublicationOrder()
    let observer = "trakt-cross-instance-clear-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { order.observe($0) }
    let drainTask = Task.detached { try? await drainer.validToken() }
    guard order.waitForEntry() else {
        order.releaseCallback()
        _ = await drainTask.value
        TraktAuthBoundary.removeObserver(key: observer)
        return false
    }
    let clearTask = Task.detached { await clearer.signOut() }
    let clearEntered = await waitForPendingBoundary(clearer)
    let stayedInstalledWhileDispatchBlocked = store.store.certifiedRead(active) != .missing
        && store.store.certifiedRead(publication) == .value("dispatching:\(session.rawValue)")
        && order.snapshot().isEmpty
    order.releaseCallback()
    _ = await drainTask.value
    let cleared = await clearTask.value
    let events = order.snapshot()
    TraktAuthBoundary.removeObserver(key: observer)
    return clearEntered
        && stayedInstalledWhileDispatchBlocked
        && cleared
        && store.store.certifiedRead(active) == .missing
        && store.store.certifiedRead(publication) == .missing
        && events == [session.rawValue, "nil"]
}

private func authorityPointer(
    _ store: MemoryCredentials,
    active: String
) -> String? {
    guard case let .value(pointer) = store.store.certifiedRead(active) else { return nil }
    return pointer
}

private func authorityValue(
    store: MemoryCredentials,
    active: String,
    values: [String]
) -> CredentialTupleAuthority {
    CredentialTupleAuthority(
        pointer: authorityPointer(store, active: active),
        values: values
    )
}

private func testTraktUncertainDeleteRawMissingRecovery() -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        "uncertain.trakt.access",
        "uncertain.trakt.refresh",
        "uncertain.trakt.expiry",
        "uncertain.trakt.session"
    ]
    let active = "uncertain.trakt.active"
    let cleanup = "uncertain.trakt.cleanup"
    let candidate = "uncertain.trakt.candidate"
    let pointer = UUID().uuidString.lowercased()
    let values = ["A-access", "A-refresh", "100", "A-session"]
    let store = MemoryCredentials()
    for (account, value) in zip(base, values) {
        _ = store.store.write(value, account + ".stage." + pointer)
        _ = store.store.write(value, account)
    }
    _ = store.store.write(pointer, active)
    _ = store.store.write("candidate:\(pointer)", candidate)
    store.failNextDeleteAfterPersist(for: active)
    _ = store.store.write(nil, active)
    let stage = base[0] + ".stage." + pointer
    store.failNextDeleteAfterPersist(for: stage)
    _ = store.store.write(nil, stage)

    let uncertainEvidence = store.store.certifiedRead(active) == .failure
        && store.durableValue(active) == .missing
        && store.store.certifiedRead(stage) == .failure
        && store.durableValue(stage) == .missing
    let cleared = CredentialTupleTransaction.clear(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        certifiedRead: store.store.certifiedRead,
        recoveryRead: store.store.recoveryRead,
        write: store.store.write
    )
    let complete = base.allSatisfy { store.store.certifiedRead($0) == .missing }
        && base.allSatisfy { store.store.certifiedRead($0 + ".stage." + pointer) == .missing }
        && [active, cleanup, candidate].allSatisfy { store.store.certifiedRead($0) == .missing }
    _ = namespace
    return uncertainEvidence && cleared && complete
}

private func testTraktMirrorFailAfterPersistRecovery() -> Bool {
    let base = [
        "mirror.trakt.access",
        "mirror.trakt.refresh",
        "mirror.trakt.expiry",
        "mirror.trakt.session"
    ]
    let active = "mirror.trakt.active"
    let cleanup = "mirror.trakt.cleanup"
    let candidate = "mirror.trakt.candidate"
    let pointer = UUID().uuidString.lowercased()
    let values = ["A-access", "A-refresh", "100", "A-session"]
    let authority = CredentialTupleAuthority(pointer: pointer, values: values)
    let store = MemoryCredentials()
    for (account, value) in zip(base, values) {
        _ = store.store.write(value, account + ".stage." + pointer)
    }
    _ = store.store.write(pointer, active)
    store.failNextWriteAfterPersist(containing: base[0])
    let first = CredentialTupleTransaction.transition(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        candidateValues: values,
        certifiedRead: store.store.certifiedRead,
        recoveryRead: store.store.recoveryRead,
        write: store.store.write
    )
    let invalidatedExactMirror = first == .cleanupPending(authority)
        && store.store.certifiedRead(base[0]) == .failure
        && store.durableValue(base[0]) == .value(values[0])
        && CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: store.store.certifiedRead
        ) == .authority(authority)
    let retry = CredentialTupleTransaction.transition(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        candidateValues: values,
        certifiedRead: store.store.certifiedRead,
        recoveryRead: store.store.recoveryRead,
        write: store.store.write
    )
    let repaired = retry == .alreadyActive(authority)
        && base.allSatisfy { store.store.certifiedRead($0) == .value(values[base.firstIndex(of: $0) ?? 0]) }
    return invalidatedExactMirror && repaired
}

private func testTraktClearDualReadRecovery() async -> Bool {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await adoptLiveToken(auth, label: "A")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let pointer = store.value(TraktTokenSlots.active(namespace)) else { return false }
    let publication = TraktTokenSlots.publication(namespace)
    _ = store.store.write("pending:clear-session", publication)
    store.failNextDeleteAfterPersist(for: publication)
    _ = store.store.write(nil, publication)
    let uncertainOutbox = store.store.certifiedRead(publication) == .failure
        && store.durableValue(publication) == .missing
    let recorder = TraktBoundaryCounter()
    let observerKey = "trakt-clear-dual-read-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observerKey) { _ in recorder.increment() }
    await auth.signOut()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let complete = recorder.snapshot() == 1
        && base.allSatisfy { store.store.certifiedRead($0) == .missing }
        && base.allSatisfy { store.store.certifiedRead($0 + ".stage." + pointer) == .missing }
        && [
            TraktTokenSlots.active(namespace),
            TraktTokenSlots.cleanup(namespace),
            TraktTokenSlots.candidate(namespace),
            publication
        ].allSatisfy { store.store.certifiedRead($0) == .missing }
    TraktAuthBoundary.removeObserver(key: observerKey)
    return uncertainOutbox && complete
}

private func testTraktCertifiedKeychainAdapter() -> Bool {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SourcesShared/TraktAuth.swift")
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return false }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let pointer = UUID().uuidString.lowercased()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    for (account, value) in zip(base, ["A-access", "A-refresh", "100", "A-session"]) {
        _ = Keychain.set(value, for: account + ".stage." + pointer)
    }
    let active = TraktTokenSlots.active(namespace)
    _ = Keychain.set(pointer, for: active)
    Keychain.invalidate(active)
    let rawVisible = Keychain.durableString(active) == .value(pointer)
    let certifiedClosed = Keychain.confirmedString(active) == .failure
        && TraktAuth.storedSessionID == nil
    let sourceShape = source.contains("certifiedRead: { Keychain.confirmedString($0) }")
        && source.contains("recoveryRead: { Keychain.durableString($0) }")
        && source.components(separatedBy: "sourceRead: Keychain.durableString").count - 1 == 3
        && !source.contains("credentials.durableRead")
        && !source.contains("Keychain.string")
        && !source.contains("read: Keychain.durableString")
        && !source.contains("durableRead: { Keychain.durableString($0) }")
    Keychain.reset()
    return rawVisible && certifiedClosed && sourceShape
}

private enum TraktAsyncOutcome: Equatable {
    case value(String)
    case cancelled
    case sessionChanged
    case otherFailure
}

private func captureTraktOutcome(_ operation: @escaping @Sendable () async throws -> String) async -> TraktAsyncOutcome {
    do {
        return .value(try await operation())
    } catch is CancellationError {
        return .cancelled
    } catch let error as TraktAuthError where error == .sessionChanged {
        return .sessionChanged
    } catch {
        return .otherFailure
    }
}

/// An A refresh may still be inside URLSession when B replaces the credential tuple. B must never join
/// that task, and A's eventual cleanup must not erase B's newer single-flight record.
private struct TraktRefreshFlightRaceResult {
    let setupFailure: String?
    let aOutcome: TraktAsyncOutcome
    let bOutcome: TraktAsyncOutcome
    let joinedBOutcome: TraktAsyncOutcome
    let requestCountWhileBlocked: Int
    let finalSessionMatchesB: Bool
    let finalTupleMatchesB: Bool
    let activePointerPresent: Bool
    let publicationMissing: Bool

    static func failed(_ phase: String) -> TraktRefreshFlightRaceResult { TraktRefreshFlightRaceResult(
        setupFailure: phase,
        aOutcome: .otherFailure,
        bOutcome: .otherFailure,
        joinedBOutcome: .otherFailure,
        requestCountWhileBlocked: -1,
        finalSessionMatchesB: false,
        finalTupleMatchesB: false,
        activePointerPresent: false,
        publicationMissing: false
    ) }
}

private func testTraktRefreshFlightIsBoundToCaptureAndSession() async -> TraktRefreshFlightRaceResult {
    let store = MemoryCredentials()
    let (joinStream, joinContinuation) = AsyncStream<Void>.makeStream()
    let auth = makeAuth(
        store: store,
        refreshJoinObserver: {
            joinContinuation.yield(())
            joinContinuation.finish()
        }
    )
    let expired = Int(Date().timeIntervalSince1970) - 60
    guard await auth.adoptTokens(
        access: "refresh-race-A-access",
        refresh: "refresh-race-A-refresh",
        expiryUnix: expired
    ) == .success,
    let sessionA = await auth.sessionID else { return .failed("adopt A") }

    let now = Int(Date().timeIntervalSince1970)
    let gateA = HTTPRequestGate()
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"status":"ok","token":{"access_token":"refresh-race-A-new-access","refresh_token":"refresh-race-A-new-refresh","expires_in":3600,"token_type":"bearer","created_at":\(now)}}
        """,
        gate: gateA
    )
    let refreshA = Task {
        await captureTraktOutcome { try await auth.validToken(for: sessionA) }
    }
    guard await gateA.waitUntilEnteredAsync() else {
        gateA.releaseResponse()
        _ = await refreshA.value
        return .failed("A transport gate")
    }

    guard await auth.adoptTokens(
        access: "refresh-race-B-access",
        refresh: "refresh-race-B-refresh",
        expiryUnix: expired
    ) == .success,
    let sessionB = await auth.sessionID,
    sessionB != sessionA else {
        gateA.releaseResponse()
        _ = await refreshA.value
        return .failed("adopt B")
    }

    let gateB = HTTPRequestGate()
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"status":"ok","token":{"access_token":"refresh-race-B-new-access","refresh_token":"refresh-race-B-new-refresh","expires_in":3600,"token_type":"bearer","created_at":\(now)}}
        """,
        gate: gateB
    )
    let refreshB = Task {
        await captureTraktOutcome { try await auth.validToken(for: sessionB) }
    }
    guard await gateB.waitUntilEnteredAsync() else {
        gateA.releaseResponse()
        gateB.releaseResponse()
        let resultA = await refreshA.value
        let resultB = await refreshB.value
        return TraktRefreshFlightRaceResult(
            setupFailure: "B transport gate",
            aOutcome: resultA,
            bOutcome: resultB,
            joinedBOutcome: .otherFailure,
            requestCountWhileBlocked: FixtureURLProtocol.fixture.requestSnapshots().count,
            finalSessionMatchesB: await auth.sessionID == sessionB,
            finalTupleMatchesB: false,
            activePointerPresent: false,
            publicationMissing: false
        )
    }

    gateA.releaseResponse()
    let resultA = await refreshA.value

    let joinedB = Task {
        await captureTraktOutcome { try await auth.validToken(for: sessionB) }
    }
    guard await waitForAsyncSignal(joinStream) else {
        gateB.releaseResponse()
        _ = await refreshB.value
        _ = await joinedB.value
        return .failed("exact B join callback")
    }
    let requestCountWhileBIsBlocked = FixtureURLProtocol.fixture.requestSnapshots().count
    gateB.releaseResponse()
    let resultB = await refreshB.value
    let joinedResultB = await joinedB.value
    let finalTokens = await auth.syncableTokens()
    let finalSession = await auth.sessionID
    let namespace = CredentialScopeRegistry.shared.currentNamespace()

    return TraktRefreshFlightRaceResult(
        setupFailure: nil,
        aOutcome: resultA,
        bOutcome: resultB,
        joinedBOutcome: joinedResultB,
        requestCountWhileBlocked: requestCountWhileBIsBlocked,
        finalSessionMatchesB: finalSession == sessionB,
        finalTupleMatchesB: finalTokens?.access == "refresh-race-B-new-access"
            && finalTokens?.refresh == "refresh-race-B-new-refresh",
        activePointerPresent: {
            if case .value = store.store.certifiedRead(TraktTokenSlots.active(namespace)) { return true }
            return false
        }(),
        publicationMissing: store.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .missing
    )
}

/// Cancelling only the polling task must remain a first-class cancellation even while the UI's actor
/// cancellation message is delayed. An authorized response released afterwards must publish nothing.
private struct TraktCancelledPollResult {
    let outcome: TraktAsyncOutcome
    let finalSessionAbsent: Bool
    let finalTupleAbsent: Bool
    let activePointerMissing: Bool
    let publicationMissing: Bool
    let noBoundaryPublication: Bool

    static let failed = TraktCancelledPollResult(
        outcome: .otherFailure,
        finalSessionAbsent: false,
        finalTupleAbsent: false,
        activePointerMissing: false,
        publicationMissing: false,
        noBoundaryPublication: false
    )
}

private func testTraktCancelledAuthorizedPollFailsClosed() async -> TraktCancelledPollResult {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"cancel-poll-session","user_code":"cancel-poll-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    guard let device = try? await auth.requestDeviceCode() else { return .failed }

    let recorder = TraktPublicationRecorder()
    let observer = "trakt-cancelled-poll-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { TraktAuthBoundary.removeObserver(key: observer) }

    let gate = HTTPRequestGate()
    let now = Int(Date().timeIntervalSince1970)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"status":"authorized","token":{"access_token":"cancel-poll-access","refresh_token":"cancel-poll-refresh","expires_in":3600,"token_type":"bearer","created_at":\(now)}}
        """,
        gate: gate
    )
    let polling = Task {
        await captureTraktOutcome {
            guard case let .authorized(token) = try await auth.poll(session: device.session) else {
                throw TraktAuthError.decoding
            }
            return token.accessToken
        }
    }
    guard await gate.waitUntilEnteredAsync() else {
        gate.releaseResponse()
        _ = await polling.value
        return .failed
    }
    polling.cancel()
    gate.releaseResponse()
    let outcome = await polling.value
    await auth.cancelLoginAttempt()

    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let finalSession = await auth.sessionID
    let finalTokens = await auth.syncableTokens()
    return TraktCancelledPollResult(
        outcome: outcome,
        finalSessionAbsent: finalSession == nil,
        finalTupleAbsent: finalTokens == nil,
        activePointerMissing: store.store.certifiedRead(TraktTokenSlots.active(namespace)) == .missing,
        publicationMissing: store.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .missing,
        noBoundaryPublication: recorder.snapshot().isEmpty
    )
}

private struct TraktCancelledDrainResult {
    let setupFailure: String?
    let outcome: TraktAsyncOutcome
    let finalSessionMatchesA: Bool
    let finalTupleMatchesA: Bool
    let activePointerPresent: Bool
    let publicationMissing: Bool
    let noBoundaryPublication: Bool

    static func failed(_ phase: String) -> TraktCancelledDrainResult { TraktCancelledDrainResult(
        setupFailure: phase,
        outcome: .otherFailure,
        finalSessionMatchesA: false,
        finalTupleMatchesA: false,
        activePointerPresent: false,
        publicationMissing: false,
        noBoundaryPublication: false
    ) }
}

private func testTraktCancelledPollDuringBoundaryDrainFailsClosed() async -> TraktCancelledDrainResult {
    let store = MemoryCredentials()
    let (drainStream, drainContinuation) = AsyncStream<Void>.makeStream()
    let auth = makeAuth(
        store: store,
        sessionWriteDrainObserver: {
            drainContinuation.yield(())
            drainContinuation.finish()
        }
    )
    await adoptLiveToken(auth, label: "cancel-drain-A")
    guard let sessionA = await auth.sessionID else { return .failed("adopt A") }

    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"cancel-drain-session","user_code":"cancel-drain-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    guard let device = try? await auth.requestDeviceCode() else { return .failed("request device code") }

    let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
    let activeWrite = Task {
        try? await auth.performSessionBoundWrite(expectedSession: sessionA) { _ in
            enteredContinuation.yield(())
            enteredContinuation.finish()
            for await _ in releaseStream { break }
            return true
        }
    }
    var enteredIterator = enteredStream.makeAsyncIterator()
    guard await enteredIterator.next() != nil else {
        releaseContinuation.finish()
        _ = await activeWrite.value
        return .failed("active write entry")
    }

    let recorder = TraktPublicationRecorder()
    let observer = "trakt-cancelled-drain-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { TraktAuthBoundary.removeObserver(key: observer) }

    let now = Int(Date().timeIntervalSince1970)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"status":"authorized","token":{"access_token":"cancel-drain-B-access","refresh_token":"cancel-drain-B-refresh","expires_in":3600,"token_type":"bearer","created_at":\(now)}}
        """
    )
    let polling = Task {
        await captureTraktOutcome {
            guard case let .authorized(token) = try await auth.poll(session: device.session) else {
                throw TraktAuthError.decoding
            }
            return token.accessToken
        }
    }
    guard await waitForAsyncSignal(drainStream) else {
        polling.cancel()
        releaseContinuation.yield(())
        releaseContinuation.finish()
        _ = await activeWrite.value
        _ = await polling.value
        return .failed("session write drain callback")
    }
    polling.cancel()
    releaseContinuation.yield(())
    releaseContinuation.finish()
    _ = await activeWrite.value
    let outcome = await polling.value
    await auth.cancelLoginAttempt()

    let finalTokens = await auth.syncableTokens()
    let finalSession = await auth.sessionID
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    return TraktCancelledDrainResult(
        setupFailure: nil,
        outcome: outcome,
        finalSessionMatchesA: finalSession == sessionA,
        finalTupleMatchesA: finalTokens?.access == "cancel-drain-A-access"
            && finalTokens?.refresh == "cancel-drain-A-refresh",
        activePointerPresent: {
            if case .value = store.store.certifiedRead(TraktTokenSlots.active(namespace)) { return true }
            return false
        }(),
        publicationMissing: store.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .missing,
        noBoundaryPublication: recorder.snapshot().isEmpty
    )
}

private struct TraktPostCommitCancellationResult {
    let setupFailure: String?
    let outcome: TraktAsyncOutcome
    let oneCurrentTuple: Bool
    let oneCurrentSession: Bool
    let onePublication: Bool

    static func failed(_ phase: String) -> TraktPostCommitCancellationResult {
        TraktPostCommitCancellationResult(
            setupFailure: phase,
            outcome: .otherFailure,
            oneCurrentTuple: false,
            oneCurrentSession: false,
            onePublication: false
        )
    }
}

/// The synchronous store hook runs only after the poll's precommit guard. Cancelling the polling task
/// while that write is held must linearize as authorization once the durable tuple is installed. The actor
/// invalidation is intentionally delayed until after the result, so this isolates task cancellation itself.
private func testTraktPostCommitCancellationLinearizesAuthorization() async -> TraktPostCommitCancellationResult {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"session":"postcommit-session","user_code":"postcommit-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}
        """
    )
    guard let device = try? await auth.requestDeviceCode() else {
        return .failed("request device code")
    }

    let gate = TraktStageWriteGate()
    store.installWriteHook { gate.observe($0) }
    let recorder = TraktPublicationRecorder()
    let observer = "trakt-postcommit-cancellation-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { TraktAuthBoundary.removeObserver(key: observer) }

    let now = Int(Date().timeIntervalSince1970)
    FixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"status":"authorized","token":{"access_token":"postcommit-access","refresh_token":"postcommit-refresh","expires_in":3600,"token_type":"bearer","created_at":\(now)}}
        """
    )
    let polling = Task {
        await captureTraktOutcome {
            let token = try await auth.pollForToken(
                session: device.session,
                interval: 1,
                expiresIn: 60
            )
            return token.accessToken
        }
    }
    guard gate.waitForEntry() else {
        polling.cancel()
        gate.releaseWrite()
        _ = await polling.value
        return .failed("post-precommit stage write")
    }
    polling.cancel()
    gate.releaseWrite()
    let outcome = await polling.value

    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let tokens = await auth.syncableTokens()
    let session = await auth.sessionID
    let publications = recorder.snapshot()
    let activePointerPresent: Bool
    if case .value = store.store.certifiedRead(TraktTokenSlots.active(namespace)) {
        activePointerPresent = true
    } else {
        activePointerPresent = false
    }
    await auth.cancelLoginAttempt()
    return TraktPostCommitCancellationResult(
        setupFailure: nil,
        outcome: outcome,
        oneCurrentTuple: tokens?.access == "postcommit-access"
            && tokens?.refresh == "postcommit-refresh"
            && activePointerPresent,
        oneCurrentSession: session != nil,
        onePublication: publications.count == 1 && publications.first == session?.rawValue
    )
}

private func testTraktRefreshAndCancellationSourceContract() -> Bool {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SourcesShared/TraktAuth.swift")
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return false }
    guard let pollStart = source.range(of: "private func poll(\n        session: String,"),
          let pollEnd = source.range(
              of: "    /// Run the full polling loop",
              range: pollStart.upperBound..<source.endIndex
          ),
          let loopStart = source.range(of: "func pollForToken(session: String"),
          let loopEnd = source.range(
              of: "    /// Stop the currently displayed device flow",
              range: loopStart.upperBound..<source.endIndex
          ) else { return false }
    let poll = String(source[pollStart.lowerBound..<pollEnd.lowerBound])
    let loop = String(source[loopStart.lowerBound..<loopEnd.lowerBound])
    guard let installed = poll.range(of: "let installed = await performCredentialBoundary"),
          let precommit = poll.range(of: "guard !Task.isCancelled"),
          let persist = poll.range(of: "persisted = replaceCredentialsWithNewSession"),
          let authorized = poll.range(of: "return .authorized(token)"),
          let authorizationLog = poll.range(
              of: "DiagnosticsLog.log(\"trakt-auth\", \"broker device/poll -> authorized\")"
          ) else { return false }
    let postSuccess = String(poll[authorizationLog.lowerBound..<authorized.lowerBound])
    let failurePathChecksCancellation = poll.contains(
        "guard installed, persisted else {\n                try Task.checkCancellation()\n                throw mutationAttempted ? TraktAuthError.persistenceFailure : TraktAuthError.sessionChanged\n            }"
    )
    let directLinearization = installed.lowerBound < precommit.lowerBound
        && precommit.lowerBound < persist.lowerBound
        && failurePathChecksCancellation
        && !postSuccess.contains("try Task.checkCancellation()")
    let wrapperLinearization = loop.contains(
        "case .authorized(let token):\n                return token\n            case .pending:\n                try Task.checkCancellation()"
    ) && loop.contains(
        "catch let error as TraktAuthError where error.isTransient {\n                try Task.checkCancellation()"
    )
    return source.contains("private struct TraktRefreshFlight")
        && source.contains("ownerCapture: CredentialScopeRegistry.Capture")
        && source.contains("sessionID: TraktSessionID")
        && source.contains("existing.ownerCapture == capture")
        && source.contains("existing.sessionID == expectedSession")
        && source.contains("if inFlightRefresh?.id == flightID")
        && source.contains("guard !Task.isCancelled")
        && directLinearization
        && wrapperLinearization
}

private func testExternalServicesDisconnectDurabilitySourceContract() -> Bool {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SourcesShared/ExternalServicesSettingsView.swift")
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
          let simklBoundary = source.range(of: "// MARK: - SIMKL") else { return false }

    func disconnectBody(in section: String) -> String? {
        guard let start = section.range(of: "private func disconnect() {"),
              let end = section.range(
                  of: "\n    }\n}",
                  range: start.upperBound..<section.endIndex
              ) else { return nil }
        return String(section[start.lowerBound..<end.lowerBound])
    }

    func hasDurableGuard(
        _ body: String,
        call: String,
        resetCalls: [String]
    ) -> Bool {
        guard let guardRange = body.range(of: "guard await \(call) else {"),
              let errorRange = body.range(
                  of: "errorMessage = \"Couldn't disconnect. Please try again.\"",
                  range: guardRange.upperBound..<body.endIndex
              ),
              let returnRange = body.range(
                  of: "\n                return\n            }",
                  range: errorRange.upperBound..<body.endIndex
              ) else { return false }
        let successStart = returnRange.upperBound
        return resetCalls.allSatisfy { reset in
            guard let resetRange = body.range(of: reset) else { return false }
            return resetRange.lowerBound >= successStart
        }
    }

    let traktSection = String(source[..<simklBoundary.lowerBound])
    let simklSection = String(source[simklBoundary.lowerBound...])
    guard let traktDisconnect = disconnectBody(in: traktSection),
          let simklDisconnect = disconnectBody(in: simklSection) else { return false }
    let traktGuard = hasDurableGuard(
        traktDisconnect,
        call: "TraktAuth.shared.revokeAndSignOut()",
        resetCalls: [
            "TraktSyncEngine.shared.reset()",
            "TraktPlaybackShadow.shared.reset()",
            "TraktRatingsStore.shared.reset()",
            "connected = false",
            "code = nil",
            "qr = nil",
            "errorMessage = nil",
            "WatchedIndex.shared.externalShadowChanged()",
            "ImportedCatalogs.shared.removeConnectionScoped(provider: .trakt)",
            "NotificationCenter.default.post(name: TraktRailsModel.disconnectedNote, object: nil)"
        ]
    )
    let simklGuard = hasDurableGuard(
        simklDisconnect,
        call: "SIMKLAuth.shared.signOut()",
        resetCalls: [
            "SIMKLWatchedShadow.shared.reset()",
            "SIMKLRatingsStore.shared.reset()",
            "connected = false",
            "pin = nil",
            "qr = nil",
            "errorMessage = nil",
            "WatchedIndex.shared.externalShadowChanged()",
            "NotificationCenter.default.post(name: SIMKLRailsModel.disconnectedNote, object: nil)"
        ]
    )
    return traktGuard
        && simklGuard
        && traktSection.contains("if let errorMessage {")
        && simklSection.contains("if let errorMessage {")
}

private func testTraktActiveCandidateFinalizesBeforeNextPublication() -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let active = TraktTokenSlots.active(namespace)
    let cleanup = TraktTokenSlots.cleanup(namespace)
    let candidate = TraktTokenSlots.candidate(namespace)
    let publication = TraktTokenSlots.publication(namespace)
    let pointerB = UUID().uuidString.lowercased()
    let pointerA = UUID().uuidString.lowercased()
    let bValues = ["B-access", "B-refresh", "200", "B-session"]
    let cValues = ["C-access", "C-refresh", "300", "C-session"]
    let store = MemoryCredentials()

    for (account, value) in zip(base, bValues) {
        _ = store.store.write(value, account + ".stage." + pointerB)
    }
    _ = store.store.write(pointerB, active)
    _ = store.store.write("candidate:\(pointerB)", candidate)
    _ = store.store.write("post:\(pointerA)", cleanup)
    _ = store.store.write("ack:B-session", publication)

    func transition() -> CredentialTupleTransitionResult {
        CredentialTupleTransaction.transition(
            baseAccounts: base,
            activePointer: active,
            cleanupMarker: cleanup,
            candidateMarker: candidate,
            candidateValues: cValues,
            publicationMarker: publication,
            publicationValue: "C-session",
            certifiedRead: store.store.certifiedRead,
            recoveryRead: store.store.recoveryRead,
            write: store.store.write
        )
    }

    store.failNextWrite(containing: ".stage.")
    let first = transition()
    let bAuthority = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        cleanupMarker: cleanup,
        candidateMarker: candidate,
        read: store.store.certifiedRead
    )
    let bReadable = bAuthority == .authority(
        CredentialTupleAuthority(pointer: pointerB, values: bValues)
    )
    let firstSuppressed = first == .failedBeforeActivation
        && bReadable
        && store.durableValue(candidate) == .missing
        && store.durableValue(cleanup) == .missing
        && store.durableValue(publication) == .missing

    let retry = transition()
    let cAuthority = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        read: store.store.certifiedRead
    )
    let cActivated: Bool
    if case let .authority(authority) = cAuthority {
        cActivated = authority.values == cValues && authority.pointer != pointerB
    } else {
        cActivated = false
    }
    let retrySucceeded: Bool
    if case .activated = retry {
        retrySucceeded = cAuthority != .failure
            && cAuthority != .none
            && store.durableValue(publication) == .value("pending:C-session")
            && cActivated
    } else {
        retrySucceeded = false
    }
    return firstSuppressed && retrySucceeded
}

private func testTraktRemoteRecoveryAdoptionFailureDoesNotReturnStaleA(now: Int) async -> Bool {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await auth.adoptTokens(access: "A-access", refresh: "A-refresh", expiryUnix: now - 10)
    guard await auth.sessionID != nil else { return false }
    await auth.setSyncedTokenProvider {
        (access: "remote-access", refresh: "remote-refresh", expiryUnix: now + 3_600)
    }
    store.failNextWrite(containing: ".stage.")
    FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"invalid_grant"}"#)
    let returned = try? await auth.validToken()
    FixtureURLProtocol.fixture.set(status: 200)
    let finalSession = await auth.sessionID
    let finalTokens = await auth.syncableTokens()
    return returned == nil
        && finalSession == nil
        && finalTokens == nil
}

private func testTraktFinalMarkerDeleteRestoresIdentity() async -> Bool {
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    await adoptLiveToken(auth, label: "A")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let pointer = store.value(TraktTokenSlots.active(namespace)) else { return false }

    let counter = TraktBoundaryCounter()
    let observerKey = "trakt-final-marker-delete-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observerKey) { _ in counter.increment() }
    let baseline = counter.snapshot()
    store.failNextDeleteAfterPersist(for: TraktTokenSlots.active(namespace))
    await auth.signOut()
    let firstSuppressed = counter.snapshot() == baseline
        && store.durableValue(TraktTokenSlots.active(namespace)) == .value(pointer)

    let restarted = makeAuth(store: store)
    await restarted.signOut()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let complete = counter.snapshot() == baseline + 1
        && base.allSatisfy { store.durableValue($0) == .missing }
        && store.durableValue(TraktTokenSlots.active(namespace)) == .missing
        && store.durableValue(TraktTokenSlots.candidate(namespace)) == .missing
        && store.durableValue(TraktTokenSlots.cleanup(namespace)) == .missing
    TraktAuthBoundary.removeObserver(key: observerKey)
    return firstSuppressed && complete
}

private func testTraktLegacySingleSlotSourceRecheck() -> Bool {
    let source = "legacy.optional.source"
    let destination = "owner.optional.destination"
    let marker = "owner.optional.marker"
    let store = MemoryCredentials()
    _ = store.store.write("A", source)
    store.installDurableReadHook { account, result in
        if account == destination, case .value = result {
            _ = store.store.write("B", source)
        }
        return result
    }
    let result = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: source,
        destinationAccount: destination,
        claimMarkerAccount: marker,
        ownerNamespace: "account.test",
        write: store.store.write,
        durableRead: store.store.certifiedRead,
        sourceRead: store.store.recoveryRead
    )
    return result == .targetReadbackMismatch
        && store.durableValue(source) == .value("B")
        && store.durableValue(destination) == .missing
        && store.durableValue(marker) != .missing
}

private func testTraktUnknownNilPointerRecovery() -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let active = TraktTokenSlots.active(namespace)
    let cleanup = TraktTokenSlots.cleanup(namespace)
    let candidate = TraktTokenSlots.candidate(namespace)
    let oldPointer = UUID().uuidString.lowercased()
    let newPointerValues = ["B-access", "B-refresh", "200", "B-session"]
    let oldValues = ["A-access", "A-refresh", "100", "A-session"]
    let store = MemoryCredentials()
    for (account, value) in zip(base, oldValues) {
        _ = store.store.write(value, account + ".stage." + oldPointer)
        _ = store.store.write(value, account)
    }
    _ = store.store.write(oldPointer, active)
    store.failNextWriteAfterPersistMissing(containing: ".active.")

    func transition() -> CredentialTupleTransitionResult {
        CredentialTupleTransaction.transition(
            baseAccounts: base,
            activePointer: active,
            cleanupMarker: cleanup,
            candidateMarker: candidate,
            candidateValues: newPointerValues,
            certifiedRead: store.store.certifiedRead,
            recoveryRead: store.store.recoveryRead,
            write: store.store.write
        )
    }

    let first = transition()
    let candidateMarker = store.durableValue(candidate)
    let cleanupMarker = store.durableValue(cleanup)
    let candidateMarkerIsValid: Bool = {
        guard case let .value(raw) = candidateMarker else { return false }
        return raw.hasPrefix("candidate:")
    }()
    let cleanupMarkerIsValid: Bool = {
        guard case let .value(raw) = cleanupMarker else { return false }
        return raw.hasPrefix("pre:existing:")
    }()
    let retainedAfterUnknown = first == .activationStateUnknown
        && store.durableValue(active) == .missing
        && base.allSatisfy { store.durableValue($0) == .missing }
        && base.allSatisfy { store.durableValue($0 + ".stage." + oldPointer) != .missing }
        && candidateMarkerIsValid
        && cleanupMarkerIsValid
    let retry = transition()
    let retainedAfterRetry = retry == .activationStateUnknown
        && store.durableValue(active) == .missing
        && base.allSatisfy { store.durableValue($0) == .missing }
        && candidateMarker == store.durableValue(candidate)
        && cleanupMarker == store.durableValue(cleanup)
        && base.allSatisfy { store.durableValue($0 + ".stage." + oldPointer) != .missing }
    return retainedAfterUnknown && retainedAfterRetry
}

private func testTraktStalePublicationBarriers() async -> (
    pendingDrained: Bool,
    acknowledgedFinalized: Bool,
    retryAfterMismatch: Bool,
    activeCandidateMismatchRetained: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let expiry = Int(Date().timeIntervalSince1970) + 3_600

    let pendingStore = MemoryCredentials()
    let pendingAuth = makeAuth(store: pendingStore)
    await adoptLiveToken(pendingAuth, label: "A")
    guard let pendingSessionA = await pendingAuth.sessionID else {
        return (false, false, false, false)
    }
    let pendingPublication = TraktTokenSlots.publication(namespace)
    let pendingRecorder = TraktPublicationRecorder()
    let pendingObserver = "trakt-stale-pending-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: pendingObserver) { pendingRecorder.append($0) }
    _ = pendingStore.store.write("pending:\(pendingSessionA.rawValue)", pendingPublication)
    let pendingResult = await pendingAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let pendingSessionB = await pendingAuth.sessionID
    let pendingDrained = pendingResult == .success
        && pendingSessionB != nil
        && pendingRecorder.snapshot() == [pendingSessionA.rawValue, pendingSessionB?.rawValue ?? ""]
        && pendingStore.durableValue(pendingPublication) == .missing
    TraktAuthBoundary.removeObserver(key: pendingObserver)

    let acknowledgedStore = MemoryCredentials()
    let acknowledgedAuth = makeAuth(store: acknowledgedStore)
    await adoptLiveToken(acknowledgedAuth, label: "A")
    guard let acknowledgedSessionA = await acknowledgedAuth.sessionID else {
        return (pendingDrained, false, false, false)
    }
    let acknowledgedPublication = TraktTokenSlots.publication(namespace)
    let acknowledgedRecorder = TraktPublicationRecorder()
    let acknowledgedObserver = "trakt-stale-ack-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: acknowledgedObserver) { acknowledgedRecorder.append($0) }
    _ = acknowledgedStore.store.write("ack:\(acknowledgedSessionA.rawValue)", acknowledgedPublication)
    let acknowledgedResult = await acknowledgedAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let acknowledgedSessionB = await acknowledgedAuth.sessionID
    let acknowledgedFinalized = acknowledgedResult == .success
        && acknowledgedSessionB != nil
        && acknowledgedRecorder.snapshot() == [acknowledgedSessionB?.rawValue ?? ""]
        && acknowledgedStore.durableValue(acknowledgedPublication) == .missing
    TraktAuthBoundary.removeObserver(key: acknowledgedObserver)

    let retryStore = MemoryCredentials()
    let retryAuth = makeAuth(store: retryStore)
    await adoptLiveToken(retryAuth, label: "A")
    guard let retrySessionA = await retryAuth.sessionID,
          let retryPointerA = retryStore.value(TraktTokenSlots.active(namespace)) else {
        return (pendingDrained, acknowledgedFinalized, false, false)
    }
    let retryPublication = TraktTokenSlots.publication(namespace)
    let retryRecorder = TraktPublicationRecorder()
    let retryObserver = "trakt-stale-retry-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: retryObserver) { retryRecorder.append($0) }
    _ = retryStore.store.write("pending:wrong-session", retryPublication)
    let rejected = await retryAuth.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let retainedBeforeRetry = rejected == .failure
        && retryStore.durableValue(TraktTokenSlots.active(namespace)) == .value(retryPointerA)
        && retryStore.durableValue(retryPublication) == .value("pending:wrong-session")
    _ = retryStore.store.write("pending:\(retrySessionA.rawValue)", retryPublication)
    let restarted = makeAuth(store: retryStore)
    let retryResult = await restarted.adoptTokens(
        access: "B-access",
        refresh: "B-refresh",
        expiryUnix: expiry
    )
    let retrySessionB = await restarted.sessionID
    let retryAfterMismatch = retainedBeforeRetry
        && retryResult == .success
        && retrySessionB != nil
        && retryRecorder.snapshot() == [retrySessionA.rawValue, retrySessionB?.rawValue ?? ""]
        && retryStore.durableValue(retryPublication) == .missing
    TraktAuthBoundary.removeObserver(key: retryObserver)

    let candidateStore = MemoryCredentials()
    let candidatePointer = UUID().uuidString.lowercased()
    let candidateValues = ["B-access", "B-refresh", String(expiry), "B-session"]
    let candidateBase = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    for (account, value) in zip(candidateBase, candidateValues) {
        _ = candidateStore.store.write(value, account + ".stage." + candidatePointer)
    }
    _ = candidateStore.store.write(candidatePointer, TraktTokenSlots.active(namespace))
    _ = candidateStore.store.write("candidate:\(candidatePointer)", TraktTokenSlots.candidate(namespace))
    _ = candidateStore.store.write("ack:A-session", TraktTokenSlots.publication(namespace))
    let candidateTransition = CredentialTupleTransaction.transition(
        baseAccounts: candidateBase,
        activePointer: TraktTokenSlots.active(namespace),
        cleanupMarker: TraktTokenSlots.cleanup(namespace),
        candidateMarker: TraktTokenSlots.candidate(namespace),
        candidateValues: candidateValues,
        publicationMarker: TraktTokenSlots.publication(namespace),
        publicationValue: "B-session",
        certifiedRead: candidateStore.store.certifiedRead,
        recoveryRead: candidateStore.store.recoveryRead,
        write: candidateStore.store.write
    )
    let activeCandidateMismatchRetained: Bool = {
        if case .activated = candidateTransition { return false }
        return candidateStore.durableValue(TraktTokenSlots.active(namespace)) == .value(candidatePointer)
            && candidateStore.durableValue(TraktTokenSlots.candidate(namespace)) == .value("candidate:\(candidatePointer)")
            && candidateStore.durableValue(TraktTokenSlots.publication(namespace)) == .value("ack:A-session")
            && candidateStore.durableValue(candidateBase[0] + ".stage." + candidatePointer) == .value("B-access")
    }()

    return (pendingDrained, acknowledgedFinalized, retryAfterMismatch, activeCandidateMismatchRetained)
}

private func testPendingBoundaryAdmissionAndOrdering() async -> (
    pendingObserved: Bool,
    sessionWhileDraining: TraktSessionID?,
    admittedSecondWrite: Bool,
    firstToken: String?,
    finalToken: String?,
    finalSession: TraktSessionID?
) {
    let auth = makeAuth(store: MemoryCredentials())
    await adoptLiveToken(auth, label: "A")
    guard let sessionA = await auth.sessionID else {
        return (false, nil, false, nil, nil, nil)
    }

    let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
    let firstRecorder = WriteRecorder()
    let secondRecorder = WriteRecorder()

    let firstWrite = Task {
        try? await auth.performSessionBoundWrite(expectedSession: sessionA) { token in
            enteredContinuation.yield(())
            for await _ in releaseStream { break }
            await firstRecorder.append(token)
        }
    }
    for await _ in enteredStream { break }
    enteredContinuation.finish()

    // The first boundary raises pending before it suspends on A's active write.
    let signOutBoundary = Task { await auth.signOut() }
    let pendingObserved = await waitForPendingBoundary(auth)
    let sessionWhileDraining = await auth.sessionID

    // Queue the B adoption behind sign-out. Its pending intent must also prevent a new A write
    // from entering after the active write drains but before either credential mutation.
    let adoptionBoundary = Task { await adoptLiveToken(auth, label: "B") }
    for _ in 0..<20 { await Task.yield() }
    do {
        try await auth.performSessionBoundWrite(expectedSession: sessionA) { token in
            await secondRecorder.append(token)
        }
    } catch {
        // Expected: pending boundary intent closes admission immediately.
    }

    releaseContinuation.yield(())
    releaseContinuation.finish()
    _ = await firstWrite.result
    _ = await signOutBoundary.result
    _ = await adoptionBoundary.result

    return (
        pendingObserved,
        sessionWhileDraining,
        await secondRecorder.count() != 0,
        await firstRecorder.first(),
        await auth.syncableTokens()?.access,
        await auth.sessionID
    )
}

private func testRemoteRecoveryIsNewBoundary(now: Int) async -> (
    rejectedOldRead: Bool,
    sessionA: TraktSessionID?,
    sessionB: TraktSessionID?,
    access: String?,
    refresh: String?
) {
    let auth = makeAuth(store: MemoryCredentials())
    await auth.adoptTokens(
        access: "A-access",
        refresh: "A-refresh",
        expiryUnix: now - 10
    )
    let sessionA = await auth.sessionID
    await auth.setSyncedTokenProvider {
        (
            access: "remote-access",
            refresh: "remote-refresh",
            expiryUnix: now + 3_600
        )
    }
    FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"invalid_grant"}"#)

    var rejectedOldRead = false
    if let sessionA {
        do {
            _ = try await auth.validToken(for: sessionA)
        } catch TraktAuthError.sessionChanged {
            rejectedOldRead = true
        } catch {
            rejectedOldRead = false
        }
    }
    let recovered = await auth.syncableTokens()
    return (
        rejectedOldRead,
        sessionA,
        await auth.sessionID,
        recovered?.access,
        recovered?.refresh
    )
}

private func testTraktOwnerBindCannotOvertakePreDispatchMutation() async -> Bool {
    let originalScope = CredentialScopeRegistry.shared.capture().scope
    let accountA = CredentialScope(canonicalRemoteAccountID: "f3333333-3333-4333-8333-333333333333")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "f4444444-4444-4444-8444-444444444444")!
    let captureA = await MainActor.run {
        let capture = CredentialScopeRegistry.shared.bind(accountA)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        return capture
    }
    let store = MemoryCredentials()
    let auth = makeAuth(store: store)
    guard await auth.adoptTokens(
        access: "owner-A-access",
        refresh: "owner-A-refresh",
        expiryUnix: 4_102_444_800,
        ownerCapture: captureA
    ) == .success else { return false }

    let gate = TraktStageWriteGate()
    store.installWriteHook { gate.observe($0) }
    let recorder = TraktPublicationRecorder()
    let observer = "trakt-pre-dispatch-owner-bind-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    let replacement = Task.detached {
        await auth.adoptTokens(
            access: "owner-A-rotated-access",
            refresh: "owner-A-rotated-refresh",
            expiryUnix: 4_102_444_801,
            ownerCapture: captureA
        )
    }
    guard gate.waitForEntry() else {
        gate.releaseWrite()
        _ = await replacement.value
        TraktAuthBoundary.removeObserver(key: observer)
        return false
    }
    let rejectedBind = await MainActor.run { CredentialScopeRegistry.shared.tryBind(accountB) }
    let stayedOnA = CredentialScopeRegistry.shared.isCurrent(captureA)
    let quietBeforeRelease = recorder.snapshot().isEmpty
    gate.releaseWrite()
    let replacementResult = await replacement.value
    let eventsBeforeSwitch = recorder.snapshot()

    let captureB = await MainActor.run { CredentialScopeRegistry.shared.tryBind(accountB) }
    let retryResult: CredentialMutationResult
    if let captureB {
        retryResult = await auth.adoptTokens(
            access: "owner-B-access",
            refresh: "owner-B-refresh",
            expiryUnix: 4_102_444_802,
            ownerCapture: captureB
        )
    } else {
        retryResult = .failure
    }
    let finalTokens = await auth.syncableTokens(ownerCapture: captureB)
    let finalEvents = recorder.snapshot()
    TraktAuthBoundary.removeObserver(key: observer)
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(originalScope) }
    return rejectedBind == nil
        && stayedOnA
        && quietBeforeRelease
        && replacementResult == .success
        && eventsBeforeSwitch.count == 1
        && captureB?.scope == accountB
        && retryResult == .success
        && finalTokens?.access == "owner-B-access"
        && finalEvents.count == 2
}

private func testTraktProviderRecoveryRequiresDurableStageProof() async -> (
    mismatchedSelectedClosed: Bool,
    nilActiveRetryPromotedOnce: Bool,
    manifestFailAfterPersistRetried: Bool
) {
    func manifest(_ values: [String]) -> String {
        let data = try! JSONEncoder().encode(values)
        return "v1:" + String(decoding: data, as: UTF8.self)
    }

    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        TraktTokenSlots.access(namespace),
        TraktTokenSlots.refresh(namespace),
        TraktTokenSlots.expiry(namespace),
        TraktTokenSlots.session(namespace)
    ]
    let active = TraktTokenSlots.active(namespace)
    let cleanup = TraktTokenSlots.cleanup(namespace)
    let candidate = TraktTokenSlots.candidate(namespace)
    let publication = TraktTokenSlots.publication(namespace)
    let expiry = 4_102_444_800

    let mismatchedStore = MemoryCredentials()
    let mismatchedAuth = makeAuth(store: mismatchedStore)
    guard await mismatchedAuth.adoptTokens(
        access: "proof-A-access",
        refresh: "proof-A-refresh",
        expiryUnix: expiry
    ) == .success,
    case let .authority(oldAuthority) = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: mismatchedStore.store.certifiedRead
    ),
    let oldPointer = oldAuthority.pointer,
    let session = oldAuthority.values.last else {
        return (false, false, false)
    }
    let selectedPointer = UUID().uuidString.lowercased()
    let intended = ["proof-B-access", "proof-B-refresh", String(expiry + 1), session]
    _ = mismatchedStore.store.write("candidate:\(selectedPointer)", candidate)
    _ = mismatchedStore.store.write(manifest(intended), base[0] + ".manifest." + selectedPointer)
    for (index, account) in base.enumerated() {
        let stage = account + ".stage." + selectedPointer
        if index == 0 {
            mismatchedStore.failNextWriteAfterPersist(
                containing: stage,
                persistedValue: "forged-raw-access"
            )
        }
        _ = mismatchedStore.store.write(intended[index], stage)
    }
    _ = mismatchedStore.store.write("post:\(oldPointer):\(session)", cleanup)
    _ = mismatchedStore.store.write(selectedPointer, active)

    let mismatchRecorder = TraktPublicationRecorder()
    let mismatchObserver = "trakt-provider-stage-proof-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: mismatchObserver) { mismatchRecorder.append($0) }
    let mismatchedToken = try? await mismatchedAuth.validToken()
    let mismatchedSession = await mismatchedAuth.sessionID
    let mismatchedSync = await mismatchedAuth.syncableTokens()
    let mismatchedSelectedClosed = mismatchedToken == nil
        && mismatchedSession == nil
        && mismatchedSync == nil
        && mismatchedStore.store.certifiedRead(candidate) == .value("candidate:\(selectedPointer)")
        && mismatchedStore.store.certifiedRead(base[0] + ".stage." + selectedPointer) == .failure
        && mismatchedStore.durableValue(base[0] + ".stage." + selectedPointer) == .value("forged-raw-access")
        && mismatchRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: mismatchObserver)

    let retryStore = MemoryCredentials()
    let retryAuth = makeAuth(store: retryStore)
    let retryPointer = UUID().uuidString.lowercased()
    let retrySession = UUID().uuidString.lowercased()
    let retryValues = ["retry-access", "retry-refresh", String(expiry), retrySession]
    _ = retryStore.store.write("candidate:\(retryPointer)", candidate)
    _ = retryStore.store.write(manifest(retryValues), base[0] + ".manifest." + retryPointer)
    for (account, value) in zip(base, retryValues) {
        _ = retryStore.store.write(value, account + ".stage." + retryPointer)
    }
    _ = retryStore.store.write("pending:\(retrySession)", publication)
    let retryRecorder = TraktPublicationRecorder()
    let retryObserver = "trakt-nil-active-candidate-retry-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: retryObserver) { retryRecorder.append($0) }
    let passiveRetrySession = await retryAuth.sessionID
    let passiveRetrySync = await retryAuth.syncableTokens()
    let passiveHidden = passiveRetrySession == nil
        && passiveRetrySync == nil
        && retryStore.store.certifiedRead(active) == .missing
        && retryStore.durableValue(active) == .missing
    let retry = await retryAuth.adoptTokens(
        access: retryValues[0],
        refresh: retryValues[1],
        expiryUnix: expiry
    )
    let selected = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: retryStore.store.certifiedRead
    )
    let selectedSession = await retryAuth.sessionID
    let nilActiveRetryPromotedOnce = passiveHidden
        && retry == .success
        && selected == .authority(CredentialTupleAuthority(pointer: retryPointer, values: retryValues))
        && selectedSession?.rawValue == retrySession
        && retryStore.store.certifiedRead(candidate) == .missing
        && retryStore.store.certifiedRead(publication) == .missing
        && retryRecorder.snapshot() == [retrySession]
    TraktAuthBoundary.removeObserver(key: retryObserver)

    let manifestStore = MemoryCredentials()
    let manifestAuth = makeAuth(store: manifestStore)
    let manifestRecorder = TraktPublicationRecorder()
    let manifestObserver = "trakt-manifest-retry-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: manifestObserver) { manifestRecorder.append($0) }
    manifestStore.failNextWriteAfterPersist(containing: ".manifest.")
    let firstManifestWrite = await manifestAuth.adoptTokens(
        access: "manifest-access",
        refresh: "manifest-refresh",
        expiryUnix: expiry
    )
    let uncertainManifestKeys = manifestStore.durableKeys(containing: ".manifest.")
    let sessionAfterManifestFailure = await manifestAuth.sessionID
    let manifestFailureStayedClosed = firstManifestWrite == .failure
        && uncertainManifestKeys.count == 1
        && uncertainManifestKeys.allSatisfy { manifestStore.store.certifiedRead($0) == .failure }
        && sessionAfterManifestFailure == nil
        && manifestRecorder.snapshot().isEmpty
    let manifestRetry = await manifestAuth.adoptTokens(
        access: "manifest-access",
        refresh: "manifest-refresh",
        expiryUnix: expiry
    )
    let manifestSession = await manifestAuth.sessionID
    let manifestTokens = await manifestAuth.syncableTokens()
    let manifestFailAfterPersistRetried = manifestFailureStayedClosed
        && manifestRetry == .success
        && manifestSession != nil
        && manifestTokens?.access == "manifest-access"
        && manifestTokens?.refresh == "manifest-refresh"
        && manifestStore.store.certifiedRead(candidate) == .missing
        && manifestRecorder.snapshot() == [manifestSession?.rawValue ?? ""]
    TraktAuthBoundary.removeObserver(key: manifestObserver)
    return (mismatchedSelectedClosed, nilActiveRetryPromotedOnce, manifestFailAfterPersistRetried)
}

private func testTraktExplicitLegacyMigrationFinalization() async -> (
    sessionlessFinalized: Bool,
    passiveStayedPure: Bool,
    writeFailureRetried: Bool,
    readbackFailureRetried: Bool,
    generatedSessionFailAfterPersistRetried: Bool,
    generatedSessionFailBeforePersistRetried: Bool,
    generatedSessionMismatchClosed: Bool
) {
    let originalScope = CredentialScopeRegistry.shared.capture().scope
    let owner = CredentialScope(canonicalRemoteAccountID: "f1111111-1111-4111-8111-111111111111")!
    let capture = await MainActor.run {
        let capture = CredentialScopeRegistry.shared.bind(owner)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        return capture
    }
    let namespace = capture.namespace
    let expiry = 4_102_444_800

    Keychain.reset()
    _ = Keychain.set("legacy-access", for: TraktTokenSlots.legacyAccess)
    _ = Keychain.set("legacy-refresh", for: TraktTokenSlots.legacyRefresh)
    _ = Keychain.set(String(expiry), for: TraktTokenSlots.legacyExpiry)
    let claim = TraktTokenSlots.claimLegacyGlobal(owner: owner, capture: capture)
    let recorder = TraktPublicationRecorder()
    let observer = "trakt-explicit-legacy-migration-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: observer) { recorder.append($0) }
    let keychainAuth = TraktAuth(credentials: .keychain)
    let mutationsBeforePassive = Keychain.mutationCount()
    let passiveStatic = TraktAuth.storedSessionID
    let passiveActor = await keychainAuth.sessionID
    let passiveTokens = await keychainAuth.syncableTokens(ownerCapture: capture)
    let passiveStayedPure = claim == .migrated
        && passiveStatic == nil
        && passiveActor == nil
        && passiveTokens == nil
        && Keychain.mutationCount() == mutationsBeforePassive
        && recorder.snapshot().isEmpty
    let finalized = await keychainAuth.finalizeLegacyMigration(ownerCapture: capture)
    let firstSession = await keychainAuth.sessionID
    let firstTokens = await keychainAuth.syncableTokens(ownerCapture: capture)
    let finalizedAgain = await keychainAuth.finalizeLegacyMigration(ownerCapture: capture)
    let secondSession = await keychainAuth.sessionID
    let activePointerPersisted: Bool = {
        guard case let .value(raw) = Keychain.confirmedString(TraktTokenSlots.active(namespace)) else {
            return false
        }
        return CredentialTupleTransaction.canonicalPointer(raw) != nil
    }()
    let sessionlessFinalized = finalized == .success
        && finalizedAgain == .success
        && firstSession != nil
        && secondSession == firstSession
        && activePointerPersisted
        && firstTokens?.access == "legacy-access"
        && firstTokens?.refresh == "legacy-refresh"
        && firstTokens?.expiryUnix == expiry
        && recorder.snapshot() == [firstSession?.rawValue ?? ""]
    TraktAuthBoundary.removeObserver(key: observer)

    func exerciseFailure(readback: Bool) async -> Bool {
        let store = MemoryCredentials()
        let auth = makeAuth(store: store)
        _ = store.store.write("retry-access", TraktTokenSlots.access(namespace))
        _ = store.store.write("retry-refresh", TraktTokenSlots.refresh(namespace))
        _ = store.store.write(String(expiry), TraktTokenSlots.expiry(namespace))
        let mutationsBeforePassive = store.mutationCount()
        let passiveSession = await auth.sessionID
        let passiveSync = await auth.syncableTokens(ownerCapture: capture)
        guard passiveSession == nil,
              passiveSync == nil,
              store.mutationCount() == mutationsBeforePassive else { return false }
        if readback {
            store.failNextDurableRead(containing: ".stage.")
        } else {
            store.failNextWrite(containing: ".stage.")
        }
        let first = await auth.finalizeLegacyMigration(ownerCapture: capture)
        let sessionAfterFailure = await auth.sessionID
        let preserved = store.durableValue(TraktTokenSlots.access(namespace)) == .value("retry-access")
            && store.durableValue(TraktTokenSlots.refresh(namespace)) == .value("retry-refresh")
            && store.durableValue(TraktTokenSlots.expiry(namespace)) == .value(String(expiry))
            && sessionAfterFailure == nil
        let retry = await auth.finalizeLegacyMigration(ownerCapture: capture)
        let session = await auth.sessionID
        let tokens = await auth.syncableTokens(ownerCapture: capture)
        return first == .failure
            && preserved
            && retry == .success
            && session != nil
            && tokens?.access == "retry-access"
            && tokens?.refresh == "retry-refresh"
            && tokens?.expiryUnix == expiry
    }

    let writeFailureRetried = await exerciseFailure(readback: false)
    let readbackFailureRetried = await exerciseFailure(readback: true)

    let generatedStore = MemoryCredentials()
    _ = generatedStore.store.write("generated-access", TraktTokenSlots.access(namespace))
    _ = generatedStore.store.write("generated-refresh", TraktTokenSlots.refresh(namespace))
    _ = generatedStore.store.write(String(expiry), TraktTokenSlots.expiry(namespace))
    let generatedSessionAccount = TraktTokenSlots.session(namespace)
    generatedStore.failNextWriteAfterPersist(containing: generatedSessionAccount)
    let generatedRecorder = TraktPublicationRecorder()
    let generatedObserver = "trakt-generated-session-restart-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: generatedObserver) { generatedRecorder.append($0) }
    let firstGeneratedAuth = makeAuth(store: generatedStore)
    let firstGenerated = await firstGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let rawGeneratedSession: String? = {
        guard case let .value(raw) = generatedStore.durableValue(generatedSessionAccount) else { return nil }
        return raw
    }()
    let pendingGeneratedIntent = rawGeneratedSession.map {
        generatedStore.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .value("pending:\($0)")
    } == true
    let generatedSessionBeforeRestart = await firstGeneratedAuth.sessionID
    let failedClosedBeforeRestart = firstGenerated == .failure
        && generatedStore.store.certifiedRead(generatedSessionAccount) == .failure
        && generatedSessionBeforeRestart == nil
        && generatedRecorder.snapshot().isEmpty
    let restartedGeneratedAuth = makeAuth(store: generatedStore)
    let retriedGenerated = await restartedGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let generatedSessionFailAfterPersistRetried = rawGeneratedSession.map { raw in
        retriedGenerated == .success
            && pendingGeneratedIntent
            && failedClosedBeforeRestart
            && generatedStore.store.certifiedRead(generatedSessionAccount) == .value(raw)
            && generatedStore.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .missing
            && generatedRecorder.snapshot() == [raw]
    } == true
    TraktAuthBoundary.removeObserver(key: generatedObserver)

    let missingGeneratedStore = MemoryCredentials()
    _ = missingGeneratedStore.store.write("missing-generated-access", TraktTokenSlots.access(namespace))
    _ = missingGeneratedStore.store.write("missing-generated-refresh", TraktTokenSlots.refresh(namespace))
    _ = missingGeneratedStore.store.write(String(expiry), TraktTokenSlots.expiry(namespace))
    missingGeneratedStore.failNextWriteAfterPersistMissing(containing: generatedSessionAccount)
    let missingGeneratedRecorder = TraktPublicationRecorder()
    let missingGeneratedObserver = "trakt-generated-session-missing-restart-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: missingGeneratedObserver) { missingGeneratedRecorder.append($0) }
    let firstMissingGeneratedAuth = makeAuth(store: missingGeneratedStore)
    let firstMissingGenerated = await firstMissingGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let preparedMissingGeneratedSession: String? = {
        guard case let .value(rawIntent) = missingGeneratedStore.store.certifiedRead(
            TraktTokenSlots.publication(namespace)
        ), rawIntent.hasPrefix("pending:") else { return nil }
        let prepared = String(rawIntent.dropFirst("pending:".count))
        return prepared.isEmpty ? nil : prepared
    }()
    let missingGeneratedSessionBeforeRestart = await firstMissingGeneratedAuth.sessionID
    let missingGeneratedFailedClosed = firstMissingGenerated == .failure
        && missingGeneratedStore.store.certifiedRead(generatedSessionAccount) == .failure
        && missingGeneratedStore.durableValue(generatedSessionAccount) == .missing
        && missingGeneratedSessionBeforeRestart == nil
        && missingGeneratedRecorder.snapshot().isEmpty
    let restartedMissingGeneratedAuth = makeAuth(store: missingGeneratedStore)
    let retriedMissingGenerated = await restartedMissingGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let missingGeneratedSessionAfterRestart = await restartedMissingGeneratedAuth.sessionID
    let generatedSessionFailBeforePersistRetried = preparedMissingGeneratedSession.map { prepared in
        missingGeneratedFailedClosed
            && retriedMissingGenerated == .success
            && missingGeneratedStore.store.certifiedRead(generatedSessionAccount) == .value(prepared)
            && missingGeneratedStore.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .missing
            && missingGeneratedSessionAfterRestart?.rawValue == prepared
            && missingGeneratedRecorder.snapshot() == [prepared]
    } == true
    TraktAuthBoundary.removeObserver(key: missingGeneratedObserver)

    let mismatchStore = MemoryCredentials()
    _ = mismatchStore.store.write("mismatch-access", TraktTokenSlots.access(namespace))
    _ = mismatchStore.store.write("mismatch-refresh", TraktTokenSlots.refresh(namespace))
    _ = mismatchStore.store.write(String(expiry), TraktTokenSlots.expiry(namespace))
    let expectedSession = UUID().uuidString.lowercased()
    _ = mismatchStore.store.write(
        "pending:\(expectedSession)",
        TraktTokenSlots.publication(namespace)
    )
    mismatchStore.failNextWriteAfterPersist(
        containing: generatedSessionAccount,
        persistedValue: "different-raw-session"
    )
    _ = mismatchStore.store.write(expectedSession, generatedSessionAccount)
    let mismatchRecorder = TraktPublicationRecorder()
    let mismatchObserver = "trakt-generated-session-mismatch-\(UUID().uuidString)"
    TraktAuthBoundary.observe(key: mismatchObserver) { mismatchRecorder.append($0) }
    let mismatchAuth = makeAuth(store: mismatchStore)
    let mismatchResult = await mismatchAuth.finalizeLegacyMigration(ownerCapture: capture)
    let generatedSessionMismatchClosed = mismatchResult == .failure
        && mismatchStore.store.certifiedRead(generatedSessionAccount) == .failure
        && mismatchStore.durableValue(generatedSessionAccount) == .value("different-raw-session")
        && mismatchStore.store.certifiedRead(TraktTokenSlots.publication(namespace)) == .value("pending:\(expectedSession)")
        && mismatchStore.store.certifiedRead(TraktTokenSlots.active(namespace)) == .missing
        && mismatchStore.store.certifiedRead(TraktTokenSlots.candidate(namespace)) == .missing
        && mismatchRecorder.snapshot().isEmpty
    TraktAuthBoundary.removeObserver(key: mismatchObserver)
    Keychain.reset()
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(originalScope) }
    return (
        sessionlessFinalized,
        passiveStayedPure,
        writeFailureRetried,
        readbackFailureRetried,
        generatedSessionFailAfterPersistRetried,
        generatedSessionFailBeforePersistRetried,
        generatedSessionMismatchClosed
    )
}

@main
struct TraktSessionSecurityTestRunner {
    @MainActor
    static func main() async {
        var loginAuthority = TraktLoginAttemptAuthority()
        let loginA = loginAuthority.begin()
        loginAuthority.register(code: "code-A", generation: loginA)
        expect(loginAuthority.owns(code: "code-A", generation: loginA),
               "the active Trakt device code owns its login generation")
        let loginB = loginAuthority.begin()
        loginAuthority.register(code: "code-B", generation: loginB)
        expect(!loginAuthority.owns(code: "code-A", generation: loginA),
               "starting a replacement Trakt login invalidates the old device code")
        expect(loginAuthority.owns(code: "code-B", generation: loginB),
               "the replacement Trakt device code owns only the new generation")
        loginAuthority.invalidate()
        expect(!loginAuthority.owns(code: "code-B", generation: loginB),
               "an account boundary invalidates an in-flight Trakt login")

        let refreshRace = await testTraktRefreshFlightIsBoundToCaptureAndSession()
        expect(refreshRace.setupFailure == nil,
               "Trakt refresh race reached its exact join checkpoint (\(refreshRace.setupFailure ?? "complete"))")
        expect(refreshRace.aOutcome == .cancelled || refreshRace.aOutcome == .sessionChanged,
               "Trakt stale A refresh is cancelled or session-rejected (\(refreshRace.aOutcome))")
        expect(refreshRace.bOutcome == .value("refresh-race-B-new-access"),
               "Trakt replacement B refresh returns only B's refreshed access token (\(refreshRace.bOutcome))")
        expect(refreshRace.joinedBOutcome == .value("refresh-race-B-new-access"),
               "Trakt exact B joiner receives B's shared refresh result")
        expect(refreshRace.requestCountWhileBlocked == 1,
               "Trakt exact B join branch emits no duplicate broker request")
        expect(refreshRace.finalSessionMatchesB,
               "Trakt stale A cleanup preserves B's session identity")
        expect(refreshRace.finalTupleMatchesB,
               "Trakt stale A cannot mutate B's final access/refresh tuple")
        expect(refreshRace.activePointerPresent,
               "Trakt B refresh leaves one certified active pointer")
        expect(refreshRace.publicationMissing,
               "Trakt same-session B refresh leaves no pending publication marker")

        let cancelledPoll = await testTraktCancelledAuthorizedPollFailsClosed()
        expect(cancelledPoll.outcome == .cancelled,
               "Trakt transport-gated poll maps task cancellation distinctly")
        expect(cancelledPoll.finalSessionAbsent,
               "Trakt cancelled first-login poll creates no session")
        expect(cancelledPoll.finalTupleAbsent,
               "Trakt cancelled first-login poll creates no credential tuple")
        expect(cancelledPoll.activePointerMissing,
               "Trakt cancelled first-login poll creates no active pointer")
        expect(cancelledPoll.publicationMissing,
               "Trakt cancelled first-login poll creates no publication marker")
        expect(cancelledPoll.noBoundaryPublication,
               "Trakt cancelled first-login poll emits no boundary publication")

        let cancelledDrain = await testTraktCancelledPollDuringBoundaryDrainFailsClosed()
        expect(cancelledDrain.setupFailure == nil,
               "Trakt cancellation race reached its exact drain checkpoint (\(cancelledDrain.setupFailure ?? "complete"))")
        expect(cancelledDrain.outcome == .cancelled,
               "Trakt drain-gated poll maps task cancellation distinctly")
        expect(cancelledDrain.finalSessionMatchesA,
               "Trakt cancelled drain resumes with A session unchanged")
        expect(cancelledDrain.finalTupleMatchesA,
               "Trakt cancelled drain resumes with A credential tuple unchanged")
        expect(cancelledDrain.activePointerPresent,
               "Trakt cancelled drain preserves A's certified active pointer")
        expect(cancelledDrain.publicationMissing,
               "Trakt cancelled drain leaves no pending publication marker")
        expect(cancelledDrain.noBoundaryPublication,
               "Trakt cancelled drain emits no replacement boundary publication")
        let postCommitCancellation = await testTraktPostCommitCancellationLinearizesAuthorization()
        expect(postCommitCancellation.setupFailure == nil,
               "Trakt postcommit cancellation race reached its exact synchronous write checkpoint (\(postCommitCancellation.setupFailure ?? "complete"))")
        expect(postCommitCancellation.outcome == .value("postcommit-access"),
               "Trakt cancellation after the precommit guard returns the installed authorization")
        expect(postCommitCancellation.oneCurrentTuple,
               "Trakt postcommit cancellation leaves one current durable credential tuple")
        expect(postCommitCancellation.oneCurrentSession,
               "Trakt postcommit cancellation leaves one current session")
        expect(postCommitCancellation.onePublication,
               "Trakt postcommit cancellation publishes the installed session exactly once")
        expect(testTraktRefreshAndCancellationSourceContract(),
               "Trakt source keeps fail-closed precommit fences while authorization linearizes after commit")
        expect(testExternalServicesDisconnectDurabilitySourceContract(),
               "external-service UI resets only after each provider confirms its durable sign-out")

        let firstBoundaryCounter = TraktBoundaryCounter()
        let secondBoundaryCounter = TraktBoundaryCounter()
        TraktAuthBoundary.observe(key: "trakt-boundary-removal-first") { _ in
            firstBoundaryCounter.increment()
        }
        TraktAuthBoundary.observe(key: "trakt-boundary-removal-second") { _ in
            secondBoundaryCounter.increment()
        }
        TraktAuthBoundary.publish(nil)
        TraktAuthBoundary.removeObserver(key: "trakt-boundary-removal-first")
        TraktAuthBoundary.publish(nil)
        expect(firstBoundaryCounter.snapshot() == 1,
               "removing one Trakt boundary observer stops only that observer")
        expect(secondBoundaryCounter.snapshot() == 2,
               "a remaining Trakt boundary observer survives another observer's removal")
        TraktAuthBoundary.removeObserver(key: "trakt-boundary-removal-second")

        let brokerPolicy = await testTraktBrokerHostAndRequestPolicy()
        expect(brokerPolicy.hostRejected,
               "Trakt rejects a broker base outside the fixed oauth.vortx.tv origin before transport")
        expect(brokerPolicy.requestHardened,
               "Trakt broker POSTs are signed, cookie-free, cache-bypassing, and fixed-host")
        let brokerBoundary = await testTraktBrokerRedirectAndBounds()
        expect(brokerBoundary.redirectRejected,
               "Trakt rejects broker redirects without following the signed POST to another origin")
        expect(brokerBoundary.redirectDelegateRejected,
               "the production Trakt redirect delegate completes a 302 challenge with nil")
        expect(brokerBoundary.declaredOversizedRejected,
               "Trakt rejects a declared broker response body larger than 64 KiB")
        expect(brokerBoundary.streamedOversizedRejected,
               "Trakt rejects an undeclared broker body larger than 64 KiB without logging its contents")
        expect(await testTraktStaleBrokerLoginResponse(),
               "cancelled and superseded Trakt login generations reject delayed and stale broker sessions")
        expect(await testTraktRevokeOwnerSwitchFence(),
               "a delayed revoke captured for owner A cannot clear owner B after a switch")
        expect(await testTraktRevokeDefersUIResetUntilDurableClearSucceeds(),
               "Trakt revoke reports a failed durable clear without firing the UI reset, then clears and publishes once on retry")

        let now = Int(Date().timeIntervalSince1970)

        // A local OAuth refresh rotates tokens but preserves the random account session.
        let refreshStore = MemoryCredentials()
        let refreshAuth = makeAuth(store: refreshStore)
        await refreshAuth.adoptTokens(
            access: "old-access",
            refresh: "old-refresh",
            expiryUnix: now - 10
        )
        let beforeRefresh = await refreshAuth.sessionID
        FixtureURLProtocol.fixture.set(
            status: 200,
            json: """
            {
              "status": "ok",
              "token": {
                "access_token": "new-access",
                "refresh_token": "new-refresh",
                "expires_in": 3600,
                "token_type": "bearer",
                "created_at": \(now)
              }
            }
            """
        )
        let refreshed = try? await refreshAuth.validToken()
        expect(refreshed == "new-access", "token refresh returns the rotated access token")
        expect(await refreshAuth.sessionID == beforeRefresh,
               "token refresh preserves the authenticated session id")
        let refreshPersistenceRecovery = await testTraktRefreshPersistencePointerRecovery()
        expect(refreshPersistenceRecovery.rotatedRecovered,
               "Trakt network refresh retry recovers a fail-after-persist active pointer before currentToken")
        expect(refreshPersistenceRecovery.malformedClosed,
               "Trakt network refresh retry rejects malformed pointer evidence without token publication")
        expect(refreshPersistenceRecovery.unbackedClosed,
               "Trakt network refresh retry rejects an unbacked pointer without selecting a mixed tuple")
        let candidateStageRecovery = await testTraktCandidateStageFailAfterPersistRecovery()
        expect(candidateStageRecovery.allSlotsRecovered,
               "Trakt recovery enumerates and certifies every candidate stage after fail-after-persist")
        expect(candidateStageRecovery.mismatchedClosed,
               "Trakt mismatched candidate stage evidence remains closed without publication")
        expect(candidateStageRecovery.unbackedClosed,
               "Trakt unbacked candidate stage evidence is deleted and exact input is restaged without raw publication")
        expect(candidateStageRecovery.rotatedRefreshRecovered,
               "Trakt rotated refresh retry promotes the certified candidate without reusing the spent token")
        let emptyCandidateStageRecovery = await testTraktEmptyCandidateStageFailAfterPersistRecovery()
        expect(emptyCandidateStageRecovery.allSlotsRecovered,
               "Trakt empty first-login retry recovers every fail-after-persist staged slot through public adoption")
        expect(emptyCandidateStageRecovery.malformedClosed,
               "Trakt malformed first-login candidate evidence remains closed without publication")
        expect(emptyCandidateStageRecovery.unbackedClosed,
               "Trakt unbacked first-login candidate evidence remains closed without publication")
        let mutationPublicationGate = await testTraktMutationRecoveryPublicationGate()
        expect(mutationPublicationGate.activeMissingClosed,
               "Trakt mutation recovery does not finalize an active-missing new-session candidate without publication")
        expect(mutationPublicationGate.activeCandidateClosed,
               "Trakt mutation recovery does not finalize an active-A to B candidate without publication")
        expect(mutationPublicationGate.sameSessionRefreshRecovered,
               "Trakt same-session refresh recovery still finalizes without a new boundary publication")
        let publicationBoundaryRaces = await testTraktPublicationBoundaryRaces()
        expect(publicationBoundaryRaces.signOutOrdered,
               "Trakt observer-thread boundary reentrancy fails closed and queued sign-out still clears exactly once")
        expect(publicationBoundaryRaces.ownerSwitchOrdered,
               "Trakt owner bind does not flip under a live publication and a queued boundary keeps MainActor live")
        expect(await testTraktCrossInstanceClearWaitsForDispatch(),
               "Trakt clear from a second auth instance waits for the shared dispatch lease and publishes nil last")

        let restartStore = MemoryCredentials()
        let firstProcessAuth = makeAuth(store: restartStore)
        await adoptLiveToken(firstProcessAuth, label: "stable")
        let persistedSession = await firstProcessAuth.sessionID
        let nextProcessAuth = makeAuth(store: restartStore)
        expect(await nextProcessAuth.sessionID == persistedSession,
               "authenticated session id survives auth actor reconstruction")
        await adoptLiveToken(nextProcessAuth, label: "stable")
        expect(await nextProcessAuth.sessionID == persistedSession,
               "an identical adopted credential replay keeps the same session id")

        // A terminal broker invalid_grant clears the session and publishes the boundary before returning.
        let lossStore = MemoryCredentials()
        let lossAuth = makeAuth(store: lossStore)
        await lossAuth.adoptTokens(
            access: "loss-access",
            refresh: "loss-refresh",
            expiryUnix: now - 10
        )
        let visibility = BoundaryVisibility()
        TraktAuthBoundary.observe(key: "session-security-test") { sessionID in
            visibility.update(sessionID)
        }
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"invalid_grant"}"#)
        _ = try? await lossAuth.validToken()
        expect(await lossAuth.sessionID == nil,
               "automatic refresh invalid_grant removes the complete auth session")
        expect(!visibility.snapshot(),
               "automatic refresh invalid_grant publishes synchronous private-state invalidation")

        expect(await testBlockedOldSessionQueue(label: "live") ,
               "blocked A lifecycle cannot write A media after disconnect and B login")
        expect(await testBlockedOldSessionQueue(label: "pending"),
               "blocked A pending completion retry cannot write A media after B login")
        expect(await testOldAccountImmediateMutation(label: "watchlist", retriesAfterFailure: true),
               "failed A watchlist retry cannot rebind its intent to B")
        expect(await testOldAccountImmediateMutation(label: "rating", retriesAfterFailure: true),
               "failed A rating retry cannot rebind its intent to B")
        expect(await testOldAccountImmediateMutation(label: "check-in", retriesAfterFailure: false),
               "A check-in cannot reach final transport after B replaces A")
        expect(await testOldAccountImmediateMutation(label: "cancel", retriesAfterFailure: false),
               "A cancel cannot reach final transport after B replaces A")

        let slowWrite = await testSlowWriteCredentialLease()
        expect(slowWrite.sessionDuringWrite == slowWrite.sessionA,
               "account replacement waits while A holds its final transport lease")
        expect(slowWrite.tokenUsed == "A-access",
               "a slow A request keeps A credentials through final transport")
        expect(slowWrite.finalSession != nil && slowWrite.finalSession != slowWrite.sessionA,
               "B installs a fresh session after the slow A request releases its lease")

        let pendingBoundary = await testPendingBoundaryAdmissionAndOrdering()
        expect(pendingBoundary.pendingObserved,
               "credential replacement announces pending intent while A drains")
        expect(pendingBoundary.sessionWhileDraining != nil,
               "A remains installed only until its already-authorized write drains")
        expect(!pendingBoundary.admittedSecondWrite,
               "no new A write enters after a credential boundary becomes pending")
        expect(pendingBoundary.firstToken == "A-access",
               "the already-authorized A write completes with A credentials")
        expect(pendingBoundary.finalToken == "B-access",
               "serialized sign-out then adoption deterministically installs B")
        expect(pendingBoundary.finalSession != pendingBoundary.sessionWhileDraining,
               "the queued B adoption rotates the account session")

        let remoteRecovery = await testRemoteRecoveryIsNewBoundary(now: now)
        expect(remoteRecovery.rejectedOldRead,
               "a remotely recovered token cannot publish into the captured A read")
        expect(remoteRecovery.sessionA != nil
                    && remoteRecovery.sessionB != nil
                    && remoteRecovery.sessionA != remoteRecovery.sessionB,
               "remote recovery without an account fingerprint is a new account boundary")
        expect(remoteRecovery.access == "remote-access"
                    && remoteRecovery.refresh == "remote-refresh",
               "remote recovery installs the complete synced credential set")

        // A changed adoption is an account replacement and receives a new random identity.
        let replacementAuth = makeAuth(store: MemoryCredentials())
        await adoptLiveToken(replacementAuth, label: "A")
        let sessionA = await replacementAuth.sessionID
        await adoptLiveToken(replacementAuth, label: "B")
        let sessionB = await replacementAuth.sessionID
        expect(sessionA != nil && sessionB != nil && sessionA != sessionB,
               "account replacement rotates the authenticated session id")

        expect(await testOwnerSwitchMidAwaitAdoption(),
               "a Trakt adoption captured for A cannot write after the owner switches to B")
        expect(await testTraktOwnerBindCannotOvertakePreDispatchMutation(),
               "Trakt owner bind cannot overtake a staged credential mutation before dispatch")

        let providerStageProof = await testTraktProviderRecoveryRequiresDurableStageProof()
        expect(providerStageProof.mismatchedSelectedClosed,
               "Trakt provider recovery rejects mismatched raw selected-stage bytes without durable tuple proof")
        expect(providerStageProof.nilActiveRetryPromotedOnce,
               "Trakt public adoption retry promotes an exact nil-active pending candidate once")
        expect(providerStageProof.manifestFailAfterPersistRetried,
               "Trakt public adoption retry removes an uncertain pre-stage manifest and restages exactly")

        expect(await testTraktOutboxFencesAndDispatchingRepair(),
               "Trakt pending and dispatching outboxes fence passive, bound, unbound, and static credential surfaces until sign-out repair")
        expect(await testTraktPublicationIntentAndSameSessionRecovery(),
               "Trakt writes publication intent before promotion, retains missing-intent B, and recovers a same-session final-delete fault")
        expect(await testTraktDevicePollPersistsCredentialBoundary(),
               "Trakt device-code poll persists and publishes its credential boundary through the production path")

        let replacement = await testTraktReplacementKeepsTheLastCertifiedTuple()
        expect(replacement.mixedTuplePreserved,
               "Trakt failed delete plus failed replacement write preserves the complete A tuple")
        expect(replacement.mixedTupleRetry,
               "Trakt mixed-tuple failure retries to one complete B tuple")
        expect(replacement.stagedWriteFailurePreserved,
               "Trakt staged slot write failure does not replace the active tuple")
        expect(replacement.stagedWriteRetry,
               "Trakt staged slot write failure is retryable")
        expect(replacement.activationFailurePreserved,
               "Trakt activation-pointer failure does not replace the active tuple")
        expect(replacement.activationRetry,
               "Trakt activation-pointer failure is retryable")
        expect(replacement.stagedReadFailurePreserved,
               "Trakt staged durable read failure does not replace the active tuple")
        expect(replacement.stagedReadRetry,
               "Trakt staged durable read failure is retryable")

        let hostile = await testTraktCredentialTransactionHostiles()
        expect(hostile.exactStaging,
               "Trakt stages one complete tuple and activates one exact durable pointer")
        expect(hostile.pointerCandidate,
               "Trakt fail-after-persist pointer readback classifies the candidate without rollback")
        expect(hostile.pointerOld,
               "Trakt failed pointer write classified as old preserves the certified tuple")
        expect(hostile.pointerUnknown,
               "Trakt unknown pointer readback fails closed without a rollback guess")
        expect(hostile.candidateRetention,
               "Trakt retains the candidate marker until its exact staged tuple is cleaned")
        expect(hostile.legacyPreRecovery,
               "Trakt legacy pre marker with no active pointer cleans its old stage before the marker")
        expect(hostile.repairMarkerGate,
               "Trakt legacy session repair requires durable absence of active, cleanup, and candidate markers")
        expect(hostile.exactDurableReads,
               "Trakt token and session reads use one exact durable selected tuple")
        expect(hostile.postCleanupRetry,
               "Trakt post-activation cleanup failure suppresses publication and restart retries exact B")
        expect(hostile.postMirrorRetry,
               "Trakt post-pointer session mirror failure suppresses currentSessionID until exact B retry")
        expect(hostile.signOutRetry,
               "Trakt sign-out cleans active/candidate/pre identities before publishing nil and retains retry state")
        expect(hostile.malformedPointerClosed,
               "Trakt malformed pointer identities fail closed")
        expect(hostile.createdAtBestEffort,
               "Trakt createdAt failure does not contradict an activated four-slot B tuple")
        expect(testTraktUnknownNilPointerRecovery(),
               "Trakt unknown nil-pointer recovery retains every stage and marker without certifying a mirror")
        let stalePublication = await testTraktStalePublicationBarriers()
        expect(stalePublication.pendingDrained,
               "Trakt drains a matching pending publication before replacing the active tuple")
        expect(stalePublication.acknowledgedFinalized,
               "Trakt finalizes a matching acknowledged publication before replacing the active tuple")
        expect(stalePublication.retryAfterMismatch,
               "Trakt retains a mismatched publication barrier and retries it safely after restart")
        expect(stalePublication.activeCandidateMismatchRetained,
               "Trakt active-candidate recovery retains a mismatched publication marker and tuple")
        expect(await testTraktRemoteRecoveryAdoptionFailureDoesNotReturnStaleA(now: now),
               "Trakt synced-token adoption failure returns nil instead of stale A")
        expect(await testTraktFinalMarkerDeleteRestoresIdentity(),
               "Trakt uncertain final-marker deletion restores a discoverable identity for restart cleanup")
        expect(testTraktLegacySingleSlotSourceRecheck(),
               "Trakt optional legacy migration rechecks the source immediately before deletion")
        let publicPointerRecovery = await testTraktPublicRetryRecoversActivePointer()
        expect(publicPointerRecovery.publicRetry,
               "Trakt public adoption retry recovers an invalidated active pointer before replay")
        expect(publicPointerRecovery.malformedClosed,
               "Trakt public retry rejects malformed raw pointer evidence without publication")
        expect(publicPointerRecovery.mismatchedClosed,
               "Trakt public retry rejects a canonical pointer with no certified tuple stages")
        let publicCandidateRecovery = await testTraktPublicRetryAfterCandidatePersistenceFailures()
        expect(publicCandidateRecovery.activePointer,
               "Trakt public mutation retry recovers an uncertain active-pointer write")
        expect(publicCandidateRecovery.cleanupStage,
               "Trakt public mutation retry recovers an uncertain cleanup-stage write")
        expect(publicCandidateRecovery.cleanupMarker,
               "Trakt public mutation retry recovers an uncertain cleanup-marker write")
        expect(publicCandidateRecovery.mirror,
               "Trakt public mutation retry recovers an uncertain mirror write")
        expect(publicCandidateRecovery.missingIntentClosed,
               "Trakt public mutation retry keeps a selected candidate closed when its intent is missing")
        expect(testTraktActiveCandidateFinalizesBeforeNextPublication(),
               "Trakt finalizes published B before a failed C stage and preserves certified B")
        expect(testTraktUncertainDeleteRawMissingRecovery(),
               "Trakt certified failure plus raw marker/stage absence retries deletion to certified absence")
        expect(testTraktMirrorFailAfterPersistRecovery(),
               "Trakt fail-after-persist mirror bytes are repaired from exact recovery evidence before authority reuse")
        expect(await testTraktClearDualReadRecovery(),
               "Trakt sign-out recovers an uncertain outbox delete before publishing the nil boundary")
        expect(testTraktCertifiedKeychainAdapter(),
               "Trakt runtime adapters use certified Keychain reads and reserve raw reads for legacy/recovery")

        let legacyFinalization = await testTraktExplicitLegacyMigrationFinalization()
        expect(legacyFinalization.sessionlessFinalized,
               "Trakt explicitly finalizes a sessionless claimed legacy triple exactly once")
        expect(legacyFinalization.passiveStayedPure,
               "Trakt passive legacy surfaces remain closed without writing or publishing")
        expect(legacyFinalization.writeFailureRetried,
               "Trakt legacy finalization preserves and retries after a staged write failure")
        expect(legacyFinalization.readbackFailureRetried,
               "Trakt legacy finalization preserves and retries after a staged readback failure")
        expect(legacyFinalization.generatedSessionFailAfterPersistRetried,
               "Trakt legacy finalization restart recovers only the generated session proven by its pending intent")
        expect(legacyFinalization.generatedSessionFailBeforePersistRetried,
               "Trakt legacy finalization restart rewrites a missing generated session proven by its pending intent")
        expect(legacyFinalization.generatedSessionMismatchClosed,
               "Trakt legacy finalization rejects raw generated-session bytes that differ from the pending intent")

        if failures.isEmpty {
            print("PASS: \(checks) Trakt session security checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
