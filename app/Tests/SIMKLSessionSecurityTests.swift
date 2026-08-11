// Standalone adversarial tests for SIMKL auth session identity and write leases.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/simkl-session-security \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/AuthenticatedHTTPTransport.swift \
//     app/SourcesShared/SIMKLAuth.swift \
//     app/Tests/SIMKLSessionSecurityTests.swift && /tmp/simkl-session-security

import Foundation

struct SIMKLPin: Codable, Sendable {
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct SIMKLPinPoll: Codable, Sendable {
    let result: String
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case result
        case accessToken = "access_token"
    }
}

enum SIMKLError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case sessionChanged
    case badURL
    case expired
    case server(status: Int)
    case transport(String)
    case decoding
}

private final class TestKeychainStore: @unchecked Sendable {
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
        if value == nil, failedDeletes.remove(account) != nil {
            volatileValues.removeValue(forKey: account)
            lock.unlock()
            return .failure
        }
        if value != nil, failedWrites.remove(account) != nil {
            if let value { volatileValues[account] = value }
            lock.unlock()
            return .failure
        }
        if let match = failedWriteSubstrings.keys.first(where: { account.contains($0) }),
           let remaining = failedWriteSubstrings[match], remaining > 0 {
            failedWriteSubstrings[match] = remaining - 1
            if let value { volatileValues[account] = value }
            else { volatileValues.removeValue(forKey: account) }
            lock.unlock()
            return .failure
        }
        if let match = failedWriteAfterPersistSubstrings.keys.first(where: { account.contains($0) }),
           let remaining = failedWriteAfterPersistSubstrings[match], remaining > 0 {
            failedWriteAfterPersistSubstrings[match] = remaining - 1
            values[account] = value
            volatileValues.removeValue(forKey: account)
            lock.unlock()
            return .failure
        }
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

    func clear() {
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

    func failNextWrite(for account: String) {
        lock.lock()
        failedWrites.insert(account)
        lock.unlock()
    }

    func failNextDelete(for account: String) {
        lock.lock()
        failedDeletes.insert(account)
        lock.unlock()
    }

    func failNextWrite(containing substring: String) {
        lock.lock()
        failedWriteSubstrings[substring, default: 0] += 1
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

    func mutationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mutations
    }
}

enum Keychain {
    private static let storage = TestKeychainStore()

    static func string(_ account: String) -> String? { storage.read(account) }
    @discardableResult
    static func set(_ value: String?, for account: String) -> CredentialMutationResult {
        storage.write(value, account)
    }
    static func durableString(_ account: String) -> CredentialDurableReadResult {
        storage.durableRead(account)
    }
    static func confirmedString(_ account: String) -> CredentialDurableReadResult {
        storage.confirmedRead(account)
    }
    static func clear() { storage.clear() }
    static func ignoreNextWrite() { storage.ignoreNextWrite() }
    static func failNextDurableRead() { storage.failNextDurableRead() }
    static func failNextDurableRead(containing substring: String) { storage.failNextDurableRead(containing: substring) }
    static func invalidate(_ account: String) { storage.invalidate(account) }
    static func mutationCount() -> Int { storage.mutationCount() }
}

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {}
}

final class MemorySIMKLCredentials: @unchecked Sendable {
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

    var store: SIMKLCredentialStore {
        SIMKLCredentialStore(
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

final class SIMKLHTTPRequestGate: @unchecked Sendable {
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

final class SIMKLHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = Data()
    private var gate: SIMKLHTTPRequestGate?

    func set(status: Int, json: String = "", gate: SIMKLHTTPRequestGate? = nil) {
        lock.lock()
        self.status = status
        body = Data(json.utf8)
        self.gate = gate
        lock.unlock()
    }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.lock()
        let status = self.status
        let body = body
        let gate = gate
        lock.unlock()
        gate?.requestStarted()
        gate?.waitForRelease()
        return (
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://fixture.invalid")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!,
            body
        )
    }
}

final class SIMKLFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = SIMKLHTTPFixture()

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

final class SIMKLBoundaryCounter: @unchecked Sendable {
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

final class SIMKLPublicationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ sessionID: SIMKLSessionID?) {
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

final class SIMKLBlockingPublicationOrder: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [String] = []

    func observe(_ sessionID: SIMKLSessionID?) {
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

final class SIMKLStageWriteGate: @unchecked Sendable {
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

final class SIMKLBoundaryAcquisitionBox: @unchecked Sendable {
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

final class SIMKLDurableReadInterleaver: @unchecked Sendable {
    private let lock = NSLock()
    private var target: String?
    private var action: (@Sendable (CredentialDurableReadResult) -> CredentialDurableReadResult)?

    func arm(
        target: String,
        action: @escaping @Sendable (CredentialDurableReadResult) -> CredentialDurableReadResult
    ) {
        lock.lock()
        self.target = target
        self.action = action
        lock.unlock()
    }

    func intercept(_ account: String, _ fallback: CredentialDurableReadResult) -> CredentialDurableReadResult {
        lock.lock()
        guard account == target,
              case .value = fallback,
              let action else {
            lock.unlock()
            return fallback
        }
        self.target = nil
        self.action = nil
        lock.unlock()
        return action(fallback)
    }
}

actor SIMKLWriteRecorder {
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

@MainActor private var failures: [String] = []
@MainActor private var checks = 0

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

private func makeSIMKLAuth() -> SIMKLAuth {
    SIMKLAuth(credentials: MemorySIMKLCredentials().store)
}

private func makeConfiguredSIMKLAuth(
    store: MemorySIMKLCredentials,
    sessionWriteDrainObserver: (@Sendable () -> Void)? = nil
) -> SIMKLAuth {
    return SIMKLAuth(
        transport: AuthenticatedHTTPTransport(
            protocolClasses: [SIMKLFixtureURLProtocol.self]
        ),
        credentials: store.store,
        configuration: SIMKLAuthConfiguration(
            clientID: "test-client",
            apiBase: "https://fixture.invalid",
            allowedAPIHosts: ["fixture.invalid"]
        ),
        sessionWriteDrainObserver: sessionWriteDrainObserver
    )
}

private func adoptSIMKL(_ auth: SIMKLAuth, label: String) async {
    await auth.adoptTokens(
        access: "\(label)-access",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3_600
    )
}

private func testSIMKLOutboxFencesAndDispatchingRepair() async -> Bool {
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(auth, label: "fence-A")
    guard let sessionA = await auth.sessionID else { return false }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let publication = SIMKLTokenSlots.publication(namespace)
    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-outbox-fence-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { SIMKLAuthBoundary.removeObserver(key: observer) }

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
        expiryUnix: Int(Date().timeIntervalSince1970) + 3_600
    )
    let reAdoptedSession = await auth.sessionID
    let reAdopted = adoptionResult == .success && reAdoptedSession != nil

    Keychain.clear()
    let staticNamespace = CredentialScopeRegistry.shared.currentNamespace()
    let staticPointer = UUID().uuidString.lowercased()
    let staticValues = ["static-access", "4102444800", "static-session"]
    let staticBase = [
        SIMKLTokenSlots.access(staticNamespace),
        SIMKLTokenSlots.expiry(staticNamespace),
        SIMKLTokenSlots.session(staticNamespace)
    ]
    for (account, value) in zip(staticBase, staticValues) {
        _ = Keychain.set(value, for: account + ".stage." + staticPointer)
    }
    _ = Keychain.set(staticPointer, for: SIMKLTokenSlots.active(staticNamespace))
    _ = Keychain.set("pending:static-session", for: SIMKLTokenSlots.publication(staticNamespace))
    let staticPendingClosed = SIMKLAuth.storedSessionID == nil
    _ = Keychain.set("dispatching:static-session", for: SIMKLTokenSlots.publication(staticNamespace))
    let staticDispatchingClosed = SIMKLAuth.storedSessionID == nil
    Keychain.clear()

    return pendingPassiveClosed
        && pendingMutationClosed
        && dispatchingClosed
        && boundaryDenied
        && repairedBySignOut
        && reAdopted
        && staticPendingClosed
        && staticDispatchingClosed
}

private func testSIMKLPublicationIntentAndSameSessionRecovery() async -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let active = SIMKLTokenSlots.active(namespace)
    let cleanup = SIMKLTokenSlots.cleanup(namespace)
    let candidate = SIMKLTokenSlots.candidate(namespace)
    let publication = SIMKLTokenSlots.publication(namespace)

    let nilActiveStore = MemorySIMKLCredentials()
    let pointerB = UUID().uuidString.lowercased()
    let valuesB = ["B-access", "4102444800", "B-session"]
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

    let missingIntentStore = MemorySIMKLCredentials()
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
        candidateValues: ["C-access", "4102444801", "C-session"],
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

    let recoveryStore = MemorySIMKLCredentials()
    let priorPointer = UUID().uuidString.lowercased()
    let session = "same-session"
    let priorValues = ["A-access", "4102444800", session]
    let rotatedValues = ["B-access", "4102444801", session]
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
    let recoveryAuth = SIMKLAuth(credentials: recoveryStore.store)
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

private func testSIMKLPinPollPersistsCredentialBoundary() async -> Bool {
    let store = MemorySIMKLCredentials()
    let auth = makeConfiguredSIMKLAuth(store: store)
    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"user_code":"pin-1","verification_url":"https://fixture.invalid/verify","expires_in":600,"interval":1}
        """
    )
    guard let pin = try? await auth.requestPin() else { return false }
    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"result":"OK","access_token":"poll-access"}
        """
    )
    guard case let .authorized(token) = try? await auth.poll(userCode: pin.userCode),
          let session = await auth.sessionID,
          let syncable = await auth.syncableTokens() else { return false }
    return token == "poll-access" && syncable.access == "poll-access" && !session.rawValue.isEmpty
}

private func waitForPendingBoundary(_ auth: SIMKLAuth) async -> Bool {
    for _ in 0..<1_000 {
        if await auth.isCredentialBoundaryPending { return true }
        await Task.yield()
    }
    return false
}

private func testSIMKLReplacementKeepsTheLastCertifiedTuple() async -> (
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

    let mixedStore = MemorySIMKLCredentials()
    let mixedAuth = SIMKLAuth(credentials: mixedStore.store)
    let mixedExpiry = expiry()
    await mixedAuth.adoptTokens(access: "A-access", expiryUnix: mixedExpiry)
    let mixedSession = await mixedAuth.sessionID
    guard let mixedSession else {
        return (false, false, false, false, false, false, false, false)
    }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    mixedStore.failNextDelete(for: SIMKLTokenSlots.access(namespace))
    mixedStore.failNextWrite(for: SIMKLTokenSlots.access(namespace))
    await mixedAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let mixedFailureSession = await mixedAuth.sessionID
    let mixedFailureTokens = await mixedAuth.syncableTokens()
    let mixedTuplePreserved = mixedFailureSession == mixedSession
        && mixedFailureTokens?.access == "A-access"
        && mixedStore.durableValue(SIMKLTokenSlots.expiry(namespace)) == .value(String(mixedExpiry))
    await mixedAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let mixedRetryTokens = await mixedAuth.syncableTokens()
    let mixedRetrySession = await mixedAuth.sessionID
    let mixedTupleRetry = mixedRetryTokens?.access == "B-access"
        && mixedRetrySession != mixedSession

    let stagedStore = MemorySIMKLCredentials()
    let stagedAuth = SIMKLAuth(credentials: stagedStore.store)
    await adoptSIMKL(stagedAuth, label: "A")
    let stagedSession = await stagedAuth.sessionID
    stagedStore.failNextWrite(containing: ".stage.")
    await stagedAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let stagedFailureSession = await stagedAuth.sessionID
    let stagedFailureTokens = await stagedAuth.syncableTokens()
    let stagedWriteFailurePreserved = stagedFailureSession == stagedSession
        && stagedFailureTokens?.access == "A-access"
    await stagedAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let stagedWriteRetry = (await stagedAuth.syncableTokens())?.access == "B-access"

    let activationStore = MemorySIMKLCredentials()
    let activationAuth = SIMKLAuth(credentials: activationStore.store)
    await adoptSIMKL(activationAuth, label: "A")
    let activationSession = await activationAuth.sessionID
    activationStore.failNextWrite(containing: ".active.")
    await activationAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let activationFailureSession = await activationAuth.sessionID
    let activationFailureTokens = await activationAuth.syncableTokens()
    let activationFailurePreserved = activationFailureSession == activationSession
        && activationFailureTokens?.access == "A-access"
    await activationAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let activationRetry = (await activationAuth.syncableTokens())?.access == "B-access"

    let readStore = MemorySIMKLCredentials()
    let readAuth = SIMKLAuth(credentials: readStore.store)
    await adoptSIMKL(readAuth, label: "A")
    let readSession = await readAuth.sessionID
    readStore.failNextDurableRead(containing: ".stage.")
    await readAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
    let stagedReadFailureSession = await readAuth.sessionID
    let stagedReadFailureTokens = await readAuth.syncableTokens()
    let stagedReadFailurePreserved = stagedReadFailureSession == readSession
        && stagedReadFailureTokens?.access == "A-access"
    await readAuth.adoptTokens(access: "B-access", expiryUnix: expiry())
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

private func testSIMKLCredentialTransactionHostiles() async -> (
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
    malformedPointerClosed: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let active = SIMKLTokenSlots.active(namespace)
    let cleanup = SIMKLTokenSlots.cleanup(namespace)
    let candidate = SIMKLTokenSlots.candidate(namespace)
    let oldPointer = UUID().uuidString.lowercased()
    let oldValues = ["A-access", "100", "A-session"]
    let newValues = ["B-access", "200", "B-session"]

    func seed(_ store: MemorySIMKLCredentials, pointer: String, values: [String], mirror: Bool = true) {
        for (account, value) in zip(base, values) {
            _ = store.store.write(value, account + ".stage." + pointer)
            if mirror { _ = store.store.write(value, account) }
        }
        _ = store.store.write(pointer, active)
    }

    func durable(_ store: MemorySIMKLCredentials, _ account: String) -> String? {
        guard case let .value(value) = store.durableValue(account) else { return nil }
        return value
    }

    func transition(
        _ store: MemorySIMKLCredentials,
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

    let exactStore = MemorySIMKLCredentials()
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

    let candidateStore = MemorySIMKLCredentials()
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
    } else {
        pointerCandidate = false
    }

    let oldStore = MemorySIMKLCredentials()
    seed(oldStore, pointer: oldPointer, values: oldValues)
    oldStore.failNextWrite(containing: ".active.")
    let oldResult = transition(oldStore)
    let pointerOld = oldResult == .failedBeforeActivation
        && durable(oldStore, active) == oldPointer
        && durable(oldStore, candidate) == nil

    let unknownStore = MemorySIMKLCredentials()
    seed(unknownStore, pointer: oldPointer, values: oldValues)
    unknownStore.failNextWriteAfterPersist(containing: ".active.", persistedValue: "not-a-canonical-pointer")
    let unknownResult = transition(unknownStore)
    let pointerUnknown = unknownResult == .activationStateUnknown
        && durable(unknownStore, active) == "not-a-canonical-pointer"
        && durable(unknownStore, candidate)?.hasPrefix("candidate:") == true
        && durable(unknownStore, cleanup)?.hasPrefix("pre:") == true

    let retentionStore = MemorySIMKLCredentials()
    seed(retentionStore, pointer: oldPointer, values: oldValues)
    retentionStore.failNextWrite(containing: ".active.")
    retentionStore.failNextDelete(containing: ".stage.")
    let retentionResult = transition(retentionStore)
    let retentionMarker = durable(retentionStore, candidate)
    let retentionPointer = retentionMarker.flatMap { raw -> String? in
        guard raw.hasPrefix("candidate:") else { return nil }
        return String(raw.dropFirst("candidate:".count))
    }
    let retentionStagePresent = retentionPointer.map {
        durable(retentionStore, base[0] + ".stage." + $0) != nil
    } ?? false
    let retentionRetry = transition(retentionStore)
    let candidateRetention = retentionResult != .activationStateUnknown
        && retentionMarker != nil
        && retentionStagePresent
        && retentionPointer.map { durable(retentionStore, base[0] + ".stage." + $0) == nil } == true
        && durable(retentionStore, candidate) == nil
        && retentionRetry != .activationStateUnknown

    let legacyStore = MemorySIMKLCredentials()
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

    func blockedRepair(_ markerAccount: String, _ markerValue: String) async -> Bool {
        let store = MemorySIMKLCredentials()
        let auth = SIMKLAuth(credentials: store.store)
        _ = store.store.write("legacy-access", SIMKLTokenSlots.access(namespace))
        _ = store.store.write("3600", SIMKLTokenSlots.expiry(namespace))
        _ = store.store.write(markerValue, markerAccount)
        return await auth.sessionID == nil && store.value(SIMKLTokenSlots.session(namespace)) == nil
    }
    let activeRepairBlocked = await blockedRepair(active, oldPointer)
    let cleanupRepairBlocked = await blockedRepair(cleanup, "pre:existing:\(oldPointer)")
    let candidateRepairBlocked = await blockedRepair(candidate, "candidate:\(oldPointer)")
    let repairMarkerGate = activeRepairBlocked && cleanupRepairBlocked && candidateRepairBlocked

    let exactReadStore = MemorySIMKLCredentials()
    let exactReadAuth = SIMKLAuth(credentials: exactReadStore.store)
    await adoptSIMKL(exactReadAuth, label: "durable")
    exactReadStore.injectVolatile("mixed-access", for: SIMKLTokenSlots.access(namespace))
    exactReadStore.injectVolatile("mixed-session", for: SIMKLTokenSlots.session(namespace))
    let exactReadSession = await exactReadAuth.sessionID
    let exactReadTokens = await exactReadAuth.syncableTokens()
    let exactReadToken = try? await exactReadAuth.validToken()
    let exactDurableReads = exactReadSession?.rawValue != "mixed-session"
        && exactReadTokens?.access == "durable-access"
        && exactReadToken == "durable-access"

    let postCleanupStore = MemorySIMKLCredentials()
    let postCleanupAuth = SIMKLAuth(credentials: postCleanupStore.store)
    await adoptSIMKL(postCleanupAuth, label: "A")
    guard let postOldPointer = durable(postCleanupStore, active) else {
        return (exactStaging, pointerCandidate, pointerOld, pointerUnknown, candidateRetention, legacyPreRecovery,
                repairMarkerGate, exactDurableReads, false, false, false, false)
    }
    postCleanupStore.failNextDelete(containing: ".stage.\(postOldPointer)")
    let postCleanupCounter = SIMKLBoundaryCounter()
    let postCleanupKey = "simkl-hostile-post-cleanup-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: postCleanupKey) { _ in postCleanupCounter.increment() }
    let postCleanupBaseline = postCleanupCounter.snapshot()
    let postExpiry = Int(Date().timeIntervalSince1970) + 3_600
    let firstCleanupResult = await postCleanupAuth.adoptTokens(access: "B-access", expiryUnix: postExpiry)
    let postCleanupFailureSession = await postCleanupAuth.sessionID
    let postCleanupSuppressed = firstCleanupResult == .failure
        && postCleanupCounter.snapshot() == postCleanupBaseline
        && postCleanupFailureSession == nil
    let restartedCleanupAuth = SIMKLAuth(credentials: postCleanupStore.store)
    let retryCleanupResult = await restartedCleanupAuth.adoptTokens(access: "B-access", expiryUnix: postExpiry)
    let retryCleanupTokens = await restartedCleanupAuth.syncableTokens()
    let retryCleanupSession = await restartedCleanupAuth.sessionID
    let postCleanupRetried = retryCleanupResult == .success
        && retryCleanupTokens?.access == "B-access"
        && retryCleanupSession != nil
        && postCleanupCounter.snapshot() == postCleanupBaseline + 1
    SIMKLAuthBoundary.removeObserver(key: postCleanupKey)
    let postCleanupRetry = postCleanupSuppressed && postCleanupRetried

    let postMirrorStore = MemorySIMKLCredentials()
    let postMirrorAuth = SIMKLAuth(credentials: postMirrorStore.store)
    await adoptSIMKL(postMirrorAuth, label: "A")
    postMirrorStore.failNextWrite(for: SIMKLTokenSlots.session(namespace))
    let postMirrorCounter = SIMKLBoundaryCounter()
    let postMirrorKey = "simkl-hostile-post-mirror-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: postMirrorKey) { _ in postMirrorCounter.increment() }
    let postMirrorBaseline = postMirrorCounter.snapshot()
    let mirrorExpiry = Int(Date().timeIntervalSince1970) + 3_600
    let firstMirrorResult = await postMirrorAuth.adoptTokens(access: "B-access", expiryUnix: mirrorExpiry)
    let postMirrorFailureSession = await postMirrorAuth.sessionID
    let postMirrorSuppressed = firstMirrorResult == .failure
        && postMirrorCounter.snapshot() == postMirrorBaseline
        && postMirrorFailureSession == nil
    let restartedMirrorAuth = SIMKLAuth(credentials: postMirrorStore.store)
    let retryMirrorResult = await restartedMirrorAuth.adoptTokens(access: "B-access", expiryUnix: mirrorExpiry)
    let retryMirrorTokens = await restartedMirrorAuth.syncableTokens()
    let retryMirrorSession = await restartedMirrorAuth.sessionID
    let postMirrorRetried = retryMirrorResult == .success
        && retryMirrorTokens?.access == "B-access"
        && retryMirrorSession != nil
        && postMirrorCounter.snapshot() == postMirrorBaseline + 1
    SIMKLAuthBoundary.removeObserver(key: postMirrorKey)
    let postMirrorRetry = postMirrorSuppressed && postMirrorRetried

    let signOutStore = MemorySIMKLCredentials()
    let signOutAuth = SIMKLAuth(credentials: signOutStore.store)
    await adoptSIMKL(signOutAuth, label: "A")
    guard let signOutOldPointer = durable(signOutStore, active) else {
        return (exactStaging, pointerCandidate, pointerOld, pointerUnknown, candidateRetention, legacyPreRecovery,
                repairMarkerGate, exactDurableReads, postCleanupRetry, postMirrorRetry, false, false)
    }
    let signOutBPointer = UUID().uuidString.lowercased()
    _ = signOutStore.store.write("candidate:\(signOutBPointer)", candidate)
    _ = signOutStore.store.write("post:\(signOutOldPointer)", cleanup)
    for (account, value) in zip(base, newValues) {
        _ = signOutStore.store.write(value, account + ".stage." + signOutBPointer)
    }
    signOutStore.failNextDelete(for: base[0] + ".stage." + signOutBPointer)
    let signOutCounter = SIMKLBoundaryCounter()
    let signOutKey = "simkl-hostile-signout-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: signOutKey) { _ in signOutCounter.increment() }
    let signOutBaseline = signOutCounter.snapshot()
    await signOutAuth.signOut()
    let failedSignOutRetained = signOutCounter.snapshot() == signOutBaseline
        && durable(signOutStore, active) == signOutOldPointer
        && durable(signOutStore, candidate) == "candidate:\(signOutBPointer)"
        && durable(signOutStore, cleanup) == "post:\(signOutOldPointer)"
        && durable(signOutStore, base[0] + ".stage." + signOutBPointer) != nil
    await signOutAuth.signOut()
    let signOutComplete = base.allSatisfy { durable(signOutStore, $0) == nil }
        && base.allSatisfy { durable(signOutStore, $0 + ".stage." + signOutOldPointer) == nil }
        && base.allSatisfy { durable(signOutStore, $0 + ".stage." + signOutBPointer) == nil }
        && durable(signOutStore, active) == nil
        && durable(signOutStore, candidate) == nil
        && durable(signOutStore, cleanup) == nil
        && signOutCounter.snapshot() == signOutBaseline + 1
    SIMKLAuthBoundary.removeObserver(key: signOutKey)
    let signOutRetry = failedSignOutRetained && signOutComplete

    let malformedStore = MemorySIMKLCredentials()
    let malformedAuth = SIMKLAuth(credentials: malformedStore.store)
    _ = malformedStore.store.write("not-a-canonical-pointer", active)
    let malformedSession = await malformedAuth.sessionID
    let malformedAdoption = await malformedAuth.adoptTokens(access: "B-access", expiryUnix: 200)
    let malformedPointerClosed = malformedSession == nil && malformedAdoption == .failure

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
        malformedPointerClosed
    )
}

private func testSIMKLActiveCandidateFinalizesBeforeNextPublication() -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let active = SIMKLTokenSlots.active(namespace)
    let cleanup = SIMKLTokenSlots.cleanup(namespace)
    let candidate = SIMKLTokenSlots.candidate(namespace)
    let publication = SIMKLTokenSlots.publication(namespace)
    let pointerB = UUID().uuidString.lowercased()
    let pointerA = UUID().uuidString.lowercased()
    let bValues = ["B-access", "200", "B-session"]
    let cValues = ["C-access", "300", "C-session"]
    let store = MemorySIMKLCredentials()

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

private func testSIMKLFinalMarkerDeleteRestoresIdentity() async -> Bool {
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(auth, label: "A")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let pointer = store.value(SIMKLTokenSlots.active(namespace)) else { return false }

    let counter = SIMKLBoundaryCounter()
    let observerKey = "simkl-final-marker-delete-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observerKey) { _ in counter.increment() }
    let baseline = counter.snapshot()
    store.failNextDeleteAfterPersist(for: SIMKLTokenSlots.active(namespace))
    await auth.signOut()
    let firstSuppressed = counter.snapshot() == baseline
        && store.durableValue(SIMKLTokenSlots.active(namespace)) == .value(pointer)

    let restarted = SIMKLAuth(credentials: store.store)
    await restarted.signOut()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let complete = counter.snapshot() == baseline + 1
        && base.allSatisfy { store.durableValue($0) == .missing }
        && store.durableValue(SIMKLTokenSlots.active(namespace)) == .missing
        && store.durableValue(SIMKLTokenSlots.candidate(namespace)) == .missing
        && store.durableValue(SIMKLTokenSlots.cleanup(namespace)) == .missing
        && store.durableValue(SIMKLTokenSlots.publication(namespace)) == .missing
    SIMKLAuthBoundary.removeObserver(key: observerKey)
    return firstSuppressed && complete
}

private func testSIMKLValidTokenSerializesOwnerSwitch() async -> Bool {
    let originalScope = CredentialScopeRegistry.shared.capture().scope
    let accountA = CredentialScope(canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let captureA = await MainActor.run {
        let capture = CredentialScopeRegistry.shared.bind(accountA)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        return capture
    }
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    let expiry = Int(Date().timeIntervalSince1970) + 3_600
    let adoption = await auth.adoptTokens(
        access: "A-access",
        expiryUnix: expiry,
        ownerCapture: captureA
    )
    guard adoption == .success, let sessionA = await auth.sessionID else {
        await MainActor.run { _ = CredentialScopeRegistry.shared.bind(originalScope) }
        return false
    }

    let namespaceB = accountB.storageNamespace
    _ = store.store.write("B-access", SIMKLTokenSlots.access(namespaceB))
    _ = store.store.write(String(expiry), SIMKLTokenSlots.expiry(namespaceB))
    _ = store.store.write("B-session", SIMKLTokenSlots.session(namespaceB))

    let interleaver = SIMKLDurableReadInterleaver()
    interleaver.arm(target: SIMKLTokenSlots.active(captureA.namespace)) { fallback in
        let finished = DispatchSemaphore(value: 0)
        Task {
            await MainActor.run {
                let captureB = CredentialScopeRegistry.shared.bind(accountB)
                _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(captureB)
                finished.signal()
            }
        }
        _ = finished.wait(timeout: .now() + 5)
        return fallback
    }
    store.installDurableReadHook { account, result in
        interleaver.intercept(account, result)
    }

    let token = try? await auth.validToken(for: sessionA)
    let stayedOnA = CredentialScopeRegistry.shared.isCurrent(captureA)
    let laterBind = await MainActor.run { CredentialScopeRegistry.shared.tryBind(accountB) }
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(originalScope) }
    return token == "A-access" && stayedOnA && laterBind?.scope == accountB
}

private func testSIMKLUnknownNilPointerRecovery() -> Bool {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let active = SIMKLTokenSlots.active(namespace)
    let cleanup = SIMKLTokenSlots.cleanup(namespace)
    let candidate = SIMKLTokenSlots.candidate(namespace)
    let oldPointer = UUID().uuidString.lowercased()
    let oldValues = ["A-access", "100", "A-session"]
    let newValues = ["B-access", "200", "B-session"]
    let store = MemorySIMKLCredentials()
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
            candidateValues: newValues,
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

private func testSIMKLStalePublicationBarriers() async -> (
    pendingDrained: Bool,
    acknowledgedFinalized: Bool,
    retryAfterMismatch: Bool,
    activeCandidateMismatchRetained: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let expiry = Int(Date().timeIntervalSince1970) + 3_600

    let pendingStore = MemorySIMKLCredentials()
    let pendingAuth = SIMKLAuth(credentials: pendingStore.store)
    await adoptSIMKL(pendingAuth, label: "A")
    guard let pendingSessionA = await pendingAuth.sessionID else {
        return (false, false, false, false)
    }
    let pendingPublication = SIMKLTokenSlots.publication(namespace)
    let pendingRecorder = SIMKLPublicationRecorder()
    let pendingObserver = "simkl-stale-pending-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: pendingObserver) { pendingRecorder.append($0) }
    _ = pendingStore.store.write("pending:\(pendingSessionA.rawValue)", pendingPublication)
    let pendingResult = await pendingAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let pendingSessionB = await pendingAuth.sessionID
    let pendingDrained = pendingResult == .success
        && pendingSessionB != nil
        && pendingRecorder.snapshot() == [pendingSessionA.rawValue, pendingSessionB?.rawValue ?? ""]
        && pendingStore.durableValue(pendingPublication) == .missing
    SIMKLAuthBoundary.removeObserver(key: pendingObserver)

    let acknowledgedStore = MemorySIMKLCredentials()
    let acknowledgedAuth = SIMKLAuth(credentials: acknowledgedStore.store)
    await adoptSIMKL(acknowledgedAuth, label: "A")
    guard let acknowledgedSessionA = await acknowledgedAuth.sessionID else {
        return (pendingDrained, false, false, false)
    }
    let acknowledgedPublication = SIMKLTokenSlots.publication(namespace)
    let acknowledgedRecorder = SIMKLPublicationRecorder()
    let acknowledgedObserver = "simkl-stale-ack-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: acknowledgedObserver) { acknowledgedRecorder.append($0) }
    _ = acknowledgedStore.store.write("ack:\(acknowledgedSessionA.rawValue)", acknowledgedPublication)
    let acknowledgedResult = await acknowledgedAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let acknowledgedSessionB = await acknowledgedAuth.sessionID
    let acknowledgedFinalized = acknowledgedResult == .success
        && acknowledgedSessionB != nil
        && acknowledgedRecorder.snapshot() == [acknowledgedSessionB?.rawValue ?? ""]
        && acknowledgedStore.durableValue(acknowledgedPublication) == .missing
    SIMKLAuthBoundary.removeObserver(key: acknowledgedObserver)

    let retryStore = MemorySIMKLCredentials()
    let retryAuth = SIMKLAuth(credentials: retryStore.store)
    await adoptSIMKL(retryAuth, label: "A")
    guard let retrySessionA = await retryAuth.sessionID,
          let retryPointerA = retryStore.value(SIMKLTokenSlots.active(namespace)) else {
        return (pendingDrained, acknowledgedFinalized, false, false)
    }
    let retryPublication = SIMKLTokenSlots.publication(namespace)
    let retryRecorder = SIMKLPublicationRecorder()
    let retryObserver = "simkl-stale-retry-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: retryObserver) { retryRecorder.append($0) }
    _ = retryStore.store.write("pending:wrong-session", retryPublication)
    let rejected = await retryAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let retainedBeforeRetry = rejected == .failure
        && retryStore.durableValue(SIMKLTokenSlots.active(namespace)) == .value(retryPointerA)
        && retryStore.durableValue(retryPublication) == .value("pending:wrong-session")
    _ = retryStore.store.write("pending:\(retrySessionA.rawValue)", retryPublication)
    let restarted = SIMKLAuth(credentials: retryStore.store)
    let retryResult = await restarted.adoptTokens(access: "B-access", expiryUnix: expiry)
    let retrySessionB = await restarted.sessionID
    let retryAfterMismatch = retainedBeforeRetry
        && retryResult == .success
        && retrySessionB != nil
        && retryRecorder.snapshot() == [retrySessionA.rawValue, retrySessionB?.rawValue ?? ""]
        && retryStore.durableValue(retryPublication) == .missing
    SIMKLAuthBoundary.removeObserver(key: retryObserver)

    let candidateStore = MemorySIMKLCredentials()
    let candidatePointer = UUID().uuidString.lowercased()
    let candidateValues = ["B-access", String(expiry), "B-session"]
    let candidateBase = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    for (account, value) in zip(candidateBase, candidateValues) {
        _ = candidateStore.store.write(value, account + ".stage." + candidatePointer)
    }
    _ = candidateStore.store.write(candidatePointer, SIMKLTokenSlots.active(namespace))
    _ = candidateStore.store.write("candidate:\(candidatePointer)", SIMKLTokenSlots.candidate(namespace))
    _ = candidateStore.store.write("ack:A-session", SIMKLTokenSlots.publication(namespace))
    let candidateTransition = CredentialTupleTransaction.transition(
        baseAccounts: candidateBase,
        activePointer: SIMKLTokenSlots.active(namespace),
        cleanupMarker: SIMKLTokenSlots.cleanup(namespace),
        candidateMarker: SIMKLTokenSlots.candidate(namespace),
        candidateValues: candidateValues,
        publicationMarker: SIMKLTokenSlots.publication(namespace),
        publicationValue: "B-session",
        certifiedRead: candidateStore.store.certifiedRead,
        recoveryRead: candidateStore.store.recoveryRead,
        write: candidateStore.store.write
    )
    let activeCandidateMismatchRetained: Bool = {
        if case .activated = candidateTransition { return false }
        return candidateStore.durableValue(SIMKLTokenSlots.active(namespace)) == .value(candidatePointer)
            && candidateStore.durableValue(SIMKLTokenSlots.candidate(namespace)) == .value("candidate:\(candidatePointer)")
            && candidateStore.durableValue(SIMKLTokenSlots.publication(namespace)) == .value("ack:A-session")
            && candidateStore.durableValue(candidateBase[0] + ".stage." + candidatePointer) == .value("B-access")
    }()

    return (pendingDrained, acknowledgedFinalized, retryAfterMismatch, activeCandidateMismatchRetained)
}

private func testSIMKLPublicRetryRecoversActivePointer() async -> (
    publicRetry: Bool,
    malformedClosed: Bool,
    mismatchedClosed: Bool
) {
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(auth, label: "A")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = SIMKLTokenSlots.active(namespace)
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let recorder = SIMKLPublicationRecorder()
    let observerKey = "simkl-public-retry-pointer-recovery-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observerKey) { recorder.append($0) }

    let expiry = Int(Date().timeIntervalSince1970) + 3_600
    store.failNextWriteAfterPersist(containing: ".active.")
    let first = await auth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let rawPointer: String? = {
        guard case let .value(raw) = store.durableValue(active) else { return nil }
        return raw
    }()
    let firstSuppressed = first == .failure
        && store.store.certifiedRead(active) == .failure
        && rawPointer != nil
        && recorder.snapshot().isEmpty

    let restarted = SIMKLAuth(credentials: store.store)
    let retry = await restarted.adoptTokens(access: "B-access", expiryUnix: expiry)
    let selected = CredentialTupleTransaction.readAuthority(
        baseAccounts: base,
        activePointer: active,
        certifiedRead: store.store.certifiedRead
    )
    let exactCertifiedTuple: Bool = {
        guard case let .authority(authority) = selected,
              authority.values.count == 3,
              authority.values[0] == "B-access",
              authority.values[1] == String(expiry),
              !authority.values[2].isEmpty,
              let pointer = rawPointer,
              store.store.certifiedRead(active) == .value(pointer) else { return false }
        return !pointer.isEmpty
    }()
    let publicRetry = firstSuppressed
        && retry == .success
        && exactCertifiedTuple
        && recorder.snapshot().count == 1
    SIMKLAuthBoundary.removeObserver(key: observerKey)

    let malformedStore = MemorySIMKLCredentials()
    let malformedAuth = SIMKLAuth(credentials: malformedStore.store)
    await adoptSIMKL(malformedAuth, label: "A")
    let malformedActive = SIMKLTokenSlots.active(namespace)
    let malformedRecorder = SIMKLPublicationRecorder()
    let malformedObserver = "simkl-public-retry-malformed-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: malformedObserver) { malformedRecorder.append($0) }
    malformedStore.failNextWriteAfterPersist(
        containing: ".active.",
        persistedValue: "not-a-canonical-pointer"
    )
    let malformedFirst = await malformedAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let malformedRetryAuth = SIMKLAuth(credentials: malformedStore.store)
    let malformedRetry = await malformedRetryAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let malformedClosed = malformedFirst == .failure
        && malformedRetry == .failure
        && malformedStore.store.certifiedRead(malformedActive) == .failure
        && malformedStore.durableValue(malformedActive) == .value("not-a-canonical-pointer")
        && malformedRecorder.snapshot().isEmpty
    SIMKLAuthBoundary.removeObserver(key: malformedObserver)

    let mismatchedStore = MemorySIMKLCredentials()
    let mismatchedAuth = SIMKLAuth(credentials: mismatchedStore.store)
    await adoptSIMKL(mismatchedAuth, label: "A")
    let mismatchedActive = SIMKLTokenSlots.active(namespace)
    let mismatchedPointer = UUID().uuidString.lowercased()
    let mismatchedRecorder = SIMKLPublicationRecorder()
    let mismatchedObserver = "simkl-public-retry-mismatched-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: mismatchedObserver) { mismatchedRecorder.append($0) }
    mismatchedStore.failNextWriteAfterPersist(
        containing: ".active.",
        persistedValue: mismatchedPointer
    )
    let mismatchedFirst = await mismatchedAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
    let mismatchedRetryAuth = SIMKLAuth(credentials: mismatchedStore.store)
    let mismatchedRetry = await mismatchedRetryAuth.adoptTokens(access: "B-access", expiryUnix: expiry)
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
    SIMKLAuthBoundary.removeObserver(key: mismatchedObserver)
    return (publicRetry, malformedClosed, mismatchedClosed)
}

private func testSIMKLPublicRetryAfterCandidatePersistenceFailures() async -> (
    activePointer: Bool,
    cleanupStage: Bool,
    cleanupMarker: Bool,
    mirror: Bool,
    missingIntentClosed: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = SIMKLTokenSlots.active(namespace)
    let publication = SIMKLTokenSlots.publication(namespace)
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let expiry = Int(Date().timeIntervalSince1970) + 3_600

    func exercise(
        label: String,
        arm: (MemorySIMKLCredentials, [String], String) -> Void
    ) async -> Bool {
        let store = MemorySIMKLCredentials()
        let auth = SIMKLAuth(credentials: store.store)
        await adoptSIMKL(auth, label: "\(label)-A")
        guard let sessionA = await auth.sessionID,
              let oldPointer = store.value(active) else { return false }
        let recorder = SIMKLPublicationRecorder()
        let observer = "simkl-public-retry-\(label)-\(UUID().uuidString)"
        SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
        arm(store, base, oldPointer)
        let first = await auth.adoptTokens(
            access: "\(label)-B-access",
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
                  selected.values.count == 3,
                  selected.values[0] == "\(label)-B-access",
                  selected.values[1] == String(expiry),
                  !selected.values[2].isEmpty else { return false }
            return publicRetry == "\(label)-B-access"
                && sessionBoundRetry == nil
                && recorder.snapshot() == [selected.values[2]]
                && store.store.certifiedRead(publication) == .missing
        }()
        SIMKLAuthBoundary.removeObserver(key: observer)
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

    let missingStore = MemorySIMKLCredentials()
    let missingAuth = SIMKLAuth(credentials: missingStore.store)
    await adoptSIMKL(missingAuth, label: "missing-A")
    guard let missingSessionA = await missingAuth.sessionID else {
        return (activePointer, cleanupStage, cleanupMarker, mirror, false)
    }
    missingStore.failNextWriteAfterPersist(containing: ".active.")
    let missingFirst = await missingAuth.adoptTokens(
        access: "missing-B-access",
        expiryUnix: expiry
    )
    _ = missingStore.store.write(nil, publication)
    let missingRecorder = SIMKLPublicationRecorder()
    let missingObserver = "simkl-public-retry-missing-intent-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: missingObserver) { missingRecorder.append($0) }
    let missingBoundRetry = try? await missingAuth.validToken(for: missingSessionA)
    let missingPublicRetry = try? await missingAuth.validToken()
    let missingIntentClosed = missingFirst == .failure
        && missingBoundRetry == nil
        && missingPublicRetry == nil
        && missingRecorder.snapshot().isEmpty
        && missingStore.store.certifiedRead(publication) == .missing
        && missingStore.store.certifiedRead(SIMKLTokenSlots.candidate(namespace)) != .missing
    SIMKLAuthBoundary.removeObserver(key: missingObserver)
    return (activePointer, cleanupStage, cleanupMarker, mirror, missingIntentClosed)
}

private func testSIMKLPublicationBoundaryRaces() async -> (
    signOutOrdered: Bool,
    ownerSwitchOrdered: Bool
) {
    let signOutStore = MemorySIMKLCredentials()
    let signOutAuth = SIMKLAuth(credentials: signOutStore.store)
    await adoptSIMKL(signOutAuth, label: "race-signout")
    guard let signOutSession = await signOutAuth.sessionID else { return (false, false) }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let signOutPublication = SIMKLTokenSlots.publication(namespace)
    _ = signOutStore.store.write("pending:\(signOutSession.rawValue)", signOutPublication)
    let signOutOrder = SIMKLBlockingPublicationOrder()
    let signOutReentry = SIMKLBoundaryAcquisitionBox()
    let signOutObserver = "simkl-publication-boundary-signout-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: signOutObserver) {
        signOutReentry.record(CredentialPublicationOutbox.acquireBoundary())
        signOutOrder.observe($0)
    }
    let signOutDrainer = Task.detached {
        try? await signOutAuth.validToken()
    }
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
        && signOutStore.store.certifiedRead(SIMKLTokenSlots.active(namespace)) == .missing
    SIMKLAuthBoundary.removeObserver(key: signOutObserver)

    let accountA = CredentialScope(canonicalRemoteAccountID: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountA) }
    let ownerStore = MemorySIMKLCredentials()
    let ownerAuth = SIMKLAuth(credentials: ownerStore.store)
    await adoptSIMKL(ownerAuth, label: "race-owner")
    guard let ownerSession = await ownerAuth.sessionID else { return (signOutOrdered, false) }
    let ownerNamespace = accountA.storageNamespace
    let ownerPublication = SIMKLTokenSlots.publication(ownerNamespace)
    _ = ownerStore.store.write("pending:\(ownerSession.rawValue)", ownerPublication)
    let ownerOrder = SIMKLBlockingPublicationOrder()
    let ownerObserver = "simkl-publication-boundary-owner-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: ownerObserver) { ownerOrder.observe($0) }
    let ownerDrainer = Task.detached {
        try? await ownerAuth.validToken()
    }
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
    SIMKLAuthBoundary.removeObserver(key: ownerObserver)

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
    return (signOutOrdered, ownerSwitchOrdered && mainActorStayedLive && queuedAcquired)
}

private func testSIMKLCrossInstanceClearWaitsForDispatch() async -> Bool {
    let store = MemorySIMKLCredentials()
    let drainer = SIMKLAuth(credentials: store.store)
    let clearer = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(drainer, label: "cross-instance-clear")
    guard let session = await drainer.sessionID else { return false }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let active = SIMKLTokenSlots.active(namespace)
    let publication = SIMKLTokenSlots.publication(namespace)
    _ = store.store.write("pending:\(session.rawValue)", publication)

    let order = SIMKLBlockingPublicationOrder()
    let observer = "simkl-cross-instance-clear-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { order.observe($0) }
    let drainTask = Task.detached { try? await drainer.validToken() }
    guard order.waitForEntry() else {
        order.releaseCallback()
        _ = await drainTask.value
        SIMKLAuthBoundary.removeObserver(key: observer)
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
    SIMKLAuthBoundary.removeObserver(key: observer)
    return clearEntered
        && stayedInstalledWhileDispatchBlocked
        && cleared
        && store.store.certifiedRead(active) == .missing
        && store.store.certifiedRead(publication) == .missing
        && events == [session.rawValue, "nil"]
}

private func testSIMKLCandidateStageFailAfterPersistRecovery() -> (
    allSlotsRecovered: Bool,
    mismatchedClosed: Bool,
    unbackedClosed: Bool
) {
    let base = [
        "stage-recovery.simkl.access",
        "stage-recovery.simkl.expiry",
        "stage-recovery.simkl.session"
    ]
    let active = "stage-recovery.simkl.active"
    let cleanup = "stage-recovery.simkl.cleanup"
    let candidate = "stage-recovery.simkl.candidate"
    let oldPointer = UUID().uuidString.lowercased()
    let candidatePointer = UUID().uuidString.lowercased()
    let oldValues = ["A-access", "100", "A-session"]
    let candidateValues = ["B-access", "200", "B-session"]

    func transition(_ store: MemorySIMKLCredentials) -> CredentialTupleTransitionResult {
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

    func selected(_ store: MemorySIMKLCredentials) -> CredentialTupleReadResult {
        CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: store.store.certifiedRead
        )
    }

    var allSlotsRecovered = true
    for failingIndex in base.indices {
        let store = MemorySIMKLCredentials()
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
        let activated: Bool
        switch first {
        case .activated:
            activated = true
        default:
            if case .activated = retry {
                activated = true
            } else {
                activated = false
            }
        }
        let finalAuthority = selected(store)
        let selectedExact: Bool = {
            guard case let .authority(authority) = finalAuthority else { return false }
            return authority.values == candidateValues
        }()
        allSlotsRecovered = allSlotsRecovered
            && candidateWasCertified
            && failAfterPersistEvidence
            && activated
            && selectedExact
            && store.store.certifiedRead(candidate) == .missing
    }

    let mismatchedStore = MemorySIMKLCredentials()
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

    let unbackedStore = MemorySIMKLCredentials()
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
    }()

    return (allSlotsRecovered, mismatchedClosed, unbackedClosed)
}

private func testSIMKLEmptyCandidateStageFailAfterPersistRecovery() async -> (
    allSlotsRecovered: Bool,
    malformedClosed: Bool,
    unbackedClosed: Bool
) {
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let active = SIMKLTokenSlots.active(namespace)
    let candidate = SIMKLTokenSlots.candidate(namespace)
    let expiry = Int(Date().timeIntervalSince1970) + 3_600
    let requested = ["first-login-access", String(expiry)]

    var allSlotsRecovered = true
    for failingIndex in base.indices {
        let store = MemorySIMKLCredentials()
        let auth = SIMKLAuth(credentials: store.store)
        let recorder = SIMKLPublicationRecorder()
        let observer = "simkl-empty-candidate-\(failingIndex)-\(UUID().uuidString)"
        SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
        store.failNextWriteAfterPersist(containing: base[failingIndex] + ".stage.")

        let first = await auth.adoptTokens(access: requested[0], expiryUnix: expiry)
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

        let retry = await auth.adoptTokens(access: requested[0], expiryUnix: expiry)
        let authority = CredentialTupleTransaction.readAuthority(
            baseAccounts: base,
            activePointer: active,
            certifiedRead: store.store.certifiedRead
        )
        var exactAuthority = false
        var finalSession: String?
        var finalPointer: String?
        if case let .authority(value) = authority,
           value.values.count == 3,
           value.values[0] == requested[0],
           value.values[1] == requested[1],
           !value.values[2].isEmpty {
            exactAuthority = true
            finalSession = value.values[2]
            finalPointer = value.pointer
        }
        let candidateResolved = candidatePointer.map { pointer in
            if finalPointer == pointer, let finalSession {
                let expected = [requested[0], requested[1], finalSession]
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
        SIMKLAuthBoundary.removeObserver(key: observer)
    }

    let malformedStore = MemorySIMKLCredentials()
    let malformedAuth = SIMKLAuth(credentials: malformedStore.store)
    let malformedRecorder = SIMKLPublicationRecorder()
    let malformedObserver = "simkl-empty-malformed-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: malformedObserver) { malformedRecorder.append($0) }
    malformedStore.failNextWriteAfterPersist(
        containing: base[0] + ".stage.",
        persistedValue: "mismatched-first-login-access"
    )
    let malformedFirst = await malformedAuth.adoptTokens(access: requested[0], expiryUnix: expiry)
    let malformedCandidate = malformedStore.value(candidate)
    malformedStore.failNextDelete(containing: base[0] + ".stage.")
    let malformedRetry = await malformedAuth.adoptTokens(access: requested[0], expiryUnix: expiry)
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
    SIMKLAuthBoundary.removeObserver(key: malformedObserver)

    let unbackedStore = MemorySIMKLCredentials()
    let unbackedAuth = SIMKLAuth(credentials: unbackedStore.store)
    let unbackedRecorder = SIMKLPublicationRecorder()
    let unbackedObserver = "simkl-empty-unbacked-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: unbackedObserver) { unbackedRecorder.append($0) }
    unbackedStore.failNextWriteAfterPersistMissing(containing: base[0] + ".stage.")
    let unbackedFirst = await unbackedAuth.adoptTokens(access: requested[0], expiryUnix: expiry)
    let unbackedCandidate = unbackedStore.value(candidate)
    let unbackedPointer = unbackedCandidate.map { String($0.dropFirst("candidate:".count)) }
    let unbackedStage = unbackedPointer.map { base[0] + ".stage." + $0 }
    unbackedStore.failNextDelete(containing: base[0] + ".stage.")
    let unbackedRetry = await unbackedAuth.adoptTokens(access: requested[0], expiryUnix: expiry)
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
    SIMKLAuthBoundary.removeObserver(key: unbackedObserver)

    return (allSlotsRecovered, malformedClosed, unbackedClosed)
}

private func testSIMKLUncertainDeleteRawMissingRecovery() -> Bool {
    let base = [
        "uncertain.simkl.access",
        "uncertain.simkl.expiry",
        "uncertain.simkl.session"
    ]
    let active = "uncertain.simkl.active"
    let cleanup = "uncertain.simkl.cleanup"
    let candidate = "uncertain.simkl.candidate"
    let pointer = UUID().uuidString.lowercased()
    let values = ["A-access", "100", "A-session"]
    let store = MemorySIMKLCredentials()
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
    return uncertainEvidence && cleared && complete
}

private func testSIMKLMirrorFailAfterPersistRecovery() -> Bool {
    let base = [
        "mirror.simkl.access",
        "mirror.simkl.expiry",
        "mirror.simkl.session"
    ]
    let active = "mirror.simkl.active"
    let cleanup = "mirror.simkl.cleanup"
    let candidate = "mirror.simkl.candidate"
    let pointer = UUID().uuidString.lowercased()
    let values = ["A-access", "100", "A-session"]
    let authority = CredentialTupleAuthority(pointer: pointer, values: values)
    let store = MemorySIMKLCredentials()
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
        && zip(base, values).allSatisfy { account, value in
            store.store.certifiedRead(account) == .value(value)
        }
    return invalidatedExactMirror && repaired
}

private func testSIMKLClearDualReadRecovery() async -> Bool {
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(auth, label: "A")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let pointer = store.value(SIMKLTokenSlots.active(namespace)) else { return false }
    let publication = SIMKLTokenSlots.publication(namespace)
    _ = store.store.write("pending:clear-session", publication)
    store.failNextDeleteAfterPersist(for: publication)
    _ = store.store.write(nil, publication)
    let uncertainOutbox = store.store.certifiedRead(publication) == .failure
        && store.durableValue(publication) == .missing
    let recorder = SIMKLBoundaryCounter()
    let observerKey = "simkl-clear-dual-read-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observerKey) { _ in recorder.increment() }
    await auth.signOut()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let complete = recorder.snapshot() == 1
        && base.allSatisfy { store.store.certifiedRead($0) == .missing }
        && base.allSatisfy { store.store.certifiedRead($0 + ".stage." + pointer) == .missing }
        && [
            SIMKLTokenSlots.active(namespace),
            SIMKLTokenSlots.cleanup(namespace),
            SIMKLTokenSlots.candidate(namespace),
            publication
        ].allSatisfy { store.store.certifiedRead($0) == .missing }
    SIMKLAuthBoundary.removeObserver(key: observerKey)
    return uncertainOutbox && complete
}

private func testSIMKLCertifiedKeychainAdapter() -> Bool {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SourcesShared/SIMKLAuth.swift")
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return false }
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    let pointer = UUID().uuidString.lowercased()
    let base = [
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    for (account, value) in zip(base, ["A-access", "100", "A-session"]) {
        _ = Keychain.set(value, for: account + ".stage." + pointer)
    }
    let active = SIMKLTokenSlots.active(namespace)
    _ = Keychain.set(pointer, for: active)
    Keychain.invalidate(active)
    let rawVisible = Keychain.durableString(active) == .value(pointer)
    let certifiedClosed = Keychain.confirmedString(active) == .failure
        && SIMKLAuth.storedSessionID == nil
    let sourceShape = source.contains("certifiedRead: { Keychain.confirmedString($0) }")
        && source.contains("recoveryRead: { Keychain.durableString($0) }")
        && source.components(separatedBy: "sourceRead: Keychain.durableString").count - 1 == 2
        && !source.contains("credentials.durableRead")
        && !source.contains("Keychain.string")
        && !source.contains("read: Keychain.durableString")
        && !source.contains("durableRead: { Keychain.durableString($0) }")
    Keychain.clear()
    return rawVisible && certifiedClosed && sourceShape
}

private func testOwnerSwitchMidAwaitAdoption() async -> Bool {
    let accountA = CredentialScope(canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(accountA) }
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(auth, label: "A")
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

    let oldAccountKept = store.value(SIMKLTokenSlots.access(accountA.storageNamespace)) == "A-access"
    let newAccountUntouched = store.value(SIMKLTokenSlots.access(accountB.storageNamespace)) == nil
    return oldAccountKept && newAccountUntouched
}

private func testDelayedAIntentCannotUseB() async -> Bool {
    let auth = makeSIMKLAuth()
    await adoptSIMKL(auth, label: "A")
    guard let sessionA = await auth.sessionID else { return false }
    await adoptSIMKL(auth, label: "B")

    let recorder = SIMKLWriteRecorder()
    do {
        try await auth.performSessionBoundWrite(expectedSession: sessionA) { token in
            await recorder.append(token)
        }
    } catch {
        // Expected: the A intent cannot acquire a lease from B.
    }
    return await recorder.count() == 0
}

private func testPendingBoundaryAdmissionAndOrdering() async -> (
    pendingObserved: Bool,
    sessionWhileDraining: SIMKLSessionID?,
    admittedSecondWrite: Bool,
    firstToken: String?,
    finalToken: String?,
    finalSession: SIMKLSessionID?
) {
    let auth = makeSIMKLAuth()
    await adoptSIMKL(auth, label: "A")
    guard let sessionA = await auth.sessionID else {
        return (false, nil, false, nil, nil, nil)
    }

    let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
    let firstRecorder = SIMKLWriteRecorder()
    let secondRecorder = SIMKLWriteRecorder()

    let firstWrite = Task {
        try? await auth.performSessionBoundWrite(expectedSession: sessionA) { token in
            enteredContinuation.yield(())
            for await _ in releaseStream { break }
            await firstRecorder.append(token)
        }
    }
    for await _ in enteredStream { break }
    enteredContinuation.finish()

    let signOutBoundary = Task { await auth.signOut() }
    let pendingObserved = await waitForPendingBoundary(auth)
    let sessionWhileDraining = await auth.sessionID
    let adoptionBoundary = Task { await adoptSIMKL(auth, label: "B") }
    for _ in 0..<20 { await Task.yield() }

    do {
        try await auth.performSessionBoundWrite(expectedSession: sessionA) { token in
            await secondRecorder.append(token)
        }
    } catch {
        // Expected: boundary intent closes admission before credential replacement.
    }

    releaseContinuation.yield(())
    releaseContinuation.finish()
    _ = await firstWrite.result
    _ = await signOutBoundary.result
    _ = await adoptionBoundary.result
    let finalTokens = await auth.syncableTokens()

    return (
        pendingObserved,
        sessionWhileDraining,
        await secondRecorder.count() != 0,
        await firstRecorder.first(),
        finalTokens?.access,
        await auth.sessionID
    )
}

private func testSIMKLOwnerBindCannotOvertakePreDispatchMutation() async -> Bool {
    let originalScope = CredentialScopeRegistry.shared.capture().scope
    let accountA = CredentialScope(canonicalRemoteAccountID: "f5555555-5555-4555-8555-555555555555")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "f6666666-6666-4666-8666-666666666666")!
    let captureA = await MainActor.run {
        let capture = CredentialScopeRegistry.shared.bind(accountA)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        return capture
    }
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    guard await auth.adoptTokens(
        access: "owner-A-access",
        expiryUnix: 4_102_444_800,
        ownerCapture: captureA
    ) == .success else { return false }

    let gate = SIMKLStageWriteGate()
    store.installWriteHook { gate.observe($0) }
    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-pre-dispatch-owner-bind-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    let replacement = Task.detached {
        await auth.adoptTokens(
            access: "owner-A-rotated-access",
            expiryUnix: 4_102_444_801,
            ownerCapture: captureA
        )
    }
    guard gate.waitForEntry() else {
        gate.releaseWrite()
        _ = await replacement.value
        SIMKLAuthBoundary.removeObserver(key: observer)
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
            expiryUnix: 4_102_444_802,
            ownerCapture: captureB
        )
    } else {
        retryResult = .failure
    }
    let finalTokens = await auth.syncableTokens(ownerCapture: captureB)
    let finalEvents = recorder.snapshot()
    SIMKLAuthBoundary.removeObserver(key: observer)
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

private func testSIMKLProviderRecoveryRequiresDurableStageProof() async -> (
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
        SIMKLTokenSlots.access(namespace),
        SIMKLTokenSlots.expiry(namespace),
        SIMKLTokenSlots.session(namespace)
    ]
    let active = SIMKLTokenSlots.active(namespace)
    let cleanup = SIMKLTokenSlots.cleanup(namespace)
    let candidate = SIMKLTokenSlots.candidate(namespace)
    let publication = SIMKLTokenSlots.publication(namespace)
    let expiry = 4_102_444_800

    let mismatchedStore = MemorySIMKLCredentials()
    let mismatchedAuth = SIMKLAuth(credentials: mismatchedStore.store)
    guard await mismatchedAuth.adoptTokens(
        access: "proof-A-access",
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
    let intended = ["proof-B-access", String(expiry + 1), session]
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

    let mismatchRecorder = SIMKLPublicationRecorder()
    let mismatchObserver = "simkl-provider-stage-proof-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: mismatchObserver) { mismatchRecorder.append($0) }
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
    SIMKLAuthBoundary.removeObserver(key: mismatchObserver)

    let retryStore = MemorySIMKLCredentials()
    let retryAuth = SIMKLAuth(credentials: retryStore.store)
    let retryPointer = UUID().uuidString.lowercased()
    let retrySession = UUID().uuidString.lowercased()
    let retryValues = ["retry-access", String(expiry), retrySession]
    _ = retryStore.store.write("candidate:\(retryPointer)", candidate)
    _ = retryStore.store.write(manifest(retryValues), base[0] + ".manifest." + retryPointer)
    for (account, value) in zip(base, retryValues) {
        _ = retryStore.store.write(value, account + ".stage." + retryPointer)
    }
    _ = retryStore.store.write("pending:\(retrySession)", publication)
    let retryRecorder = SIMKLPublicationRecorder()
    let retryObserver = "simkl-nil-active-candidate-retry-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: retryObserver) { retryRecorder.append($0) }
    let passiveRetrySession = await retryAuth.sessionID
    let passiveRetrySync = await retryAuth.syncableTokens()
    let passiveHidden = passiveRetrySession == nil
        && passiveRetrySync == nil
        && retryStore.store.certifiedRead(active) == .missing
        && retryStore.durableValue(active) == .missing
    let retry = await retryAuth.adoptTokens(
        access: retryValues[0],
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
    SIMKLAuthBoundary.removeObserver(key: retryObserver)

    let manifestStore = MemorySIMKLCredentials()
    let manifestAuth = SIMKLAuth(credentials: manifestStore.store)
    let manifestRecorder = SIMKLPublicationRecorder()
    let manifestObserver = "simkl-manifest-retry-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: manifestObserver) { manifestRecorder.append($0) }
    manifestStore.failNextWriteAfterPersist(containing: ".manifest.")
    let firstManifestWrite = await manifestAuth.adoptTokens(
        access: "manifest-access",
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
        expiryUnix: expiry
    )
    let manifestSession = await manifestAuth.sessionID
    let manifestTokens = await manifestAuth.syncableTokens()
    let manifestFailAfterPersistRetried = manifestFailureStayedClosed
        && manifestRetry == .success
        && manifestSession != nil
        && manifestTokens?.access == "manifest-access"
        && manifestStore.store.certifiedRead(candidate) == .missing
        && manifestRecorder.snapshot() == [manifestSession?.rawValue ?? ""]
    SIMKLAuthBoundary.removeObserver(key: manifestObserver)
    return (mismatchedSelectedClosed, nilActiveRetryPromotedOnce, manifestFailAfterPersistRetried)
}

private func testSIMKLExplicitLegacyMigrationFinalization() async -> (
    sessionlessFinalized: Bool,
    existingSessionPreserved: Bool,
    passiveStayedPure: Bool,
    writeFailureRetried: Bool,
    readbackFailureRetried: Bool,
    generatedSessionFailAfterPersistRetried: Bool,
    generatedSessionFailBeforePersistRetried: Bool,
    generatedSessionMismatchClosed: Bool
) {
    let originalScope = CredentialScopeRegistry.shared.capture().scope
    let owner = CredentialScope(canonicalRemoteAccountID: "f2222222-2222-4222-8222-222222222222")!
    let capture = await MainActor.run {
        let capture = CredentialScopeRegistry.shared.bind(owner)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        return capture
    }
    let namespace = capture.namespace
    let expiry = 4_102_444_800

    Keychain.clear()
    _ = Keychain.set("legacy-access", for: SIMKLTokenSlots.legacyAccess)
    _ = Keychain.set(String(expiry), for: SIMKLTokenSlots.legacyExpiry)
    let claim = SIMKLTokenSlots.claimLegacyGlobal(owner: owner, capture: capture)
    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-explicit-legacy-migration-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    let keychainAuth = SIMKLAuth(credentials: .keychain)
    let mutationsBeforePassive = Keychain.mutationCount()
    let passiveStatic = SIMKLAuth.storedSessionID
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
        guard case let .value(raw) = Keychain.confirmedString(SIMKLTokenSlots.active(namespace)) else {
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
        && firstTokens?.expiryUnix == expiry
        && recorder.snapshot() == [firstSession?.rawValue ?? ""]
    SIMKLAuthBoundary.removeObserver(key: observer)

    Keychain.clear()
    _ = Keychain.set("legacy-session-access", for: SIMKLTokenSlots.legacyAccess)
    _ = Keychain.set(String(expiry), for: SIMKLTokenSlots.legacyExpiry)
    _ = Keychain.set("preserved-legacy-session", for: SIMKLTokenSlots.legacySession)
    let sessionClaim = SIMKLTokenSlots.claimLegacyGlobal(owner: owner, capture: capture)
    let sessionRecorder = SIMKLPublicationRecorder()
    let sessionObserver = "simkl-existing-legacy-session-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: sessionObserver) { sessionRecorder.append($0) }
    let existingAuth = SIMKLAuth(credentials: .keychain)
    let existingMutationsBeforePassive = Keychain.mutationCount()
    _ = SIMKLAuth.storedSessionID
    _ = await existingAuth.sessionID
    _ = await existingAuth.syncableTokens(ownerCapture: capture)
    let existingPassivePure = Keychain.mutationCount() == existingMutationsBeforePassive
        && sessionRecorder.snapshot().isEmpty
    let existingFinalized = await existingAuth.finalizeLegacyMigration(ownerCapture: capture)
    let existingSession = await existingAuth.sessionID
    let existingPointerPersisted: Bool = {
        guard case let .value(raw) = Keychain.confirmedString(SIMKLTokenSlots.active(namespace)) else {
            return false
        }
        return CredentialTupleTransaction.canonicalPointer(raw) != nil
    }()
    let existingSessionPreserved = sessionClaim == .migrated
        && Keychain.confirmedString(SIMKLTokenSlots.session(namespace)) == .value("preserved-legacy-session")
        && existingPassivePure
        && existingFinalized == .success
        && existingSession?.rawValue == "preserved-legacy-session"
        && existingPointerPersisted
        && sessionRecorder.snapshot() == ["preserved-legacy-session"]
    SIMKLAuthBoundary.removeObserver(key: sessionObserver)

    func exerciseFailure(readback: Bool) async -> Bool {
        let store = MemorySIMKLCredentials()
        let auth = SIMKLAuth(credentials: store.store)
        _ = store.store.write("retry-access", SIMKLTokenSlots.access(namespace))
        _ = store.store.write(String(expiry), SIMKLTokenSlots.expiry(namespace))
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
        let preserved = store.durableValue(SIMKLTokenSlots.access(namespace)) == .value("retry-access")
            && store.durableValue(SIMKLTokenSlots.expiry(namespace)) == .value(String(expiry))
            && sessionAfterFailure == nil
        let retry = await auth.finalizeLegacyMigration(ownerCapture: capture)
        let session = await auth.sessionID
        let tokens = await auth.syncableTokens(ownerCapture: capture)
        return first == .failure
            && preserved
            && retry == .success
            && session != nil
            && tokens?.access == "retry-access"
            && tokens?.expiryUnix == expiry
    }

    let writeFailureRetried = await exerciseFailure(readback: false)
    let readbackFailureRetried = await exerciseFailure(readback: true)

    let generatedStore = MemorySIMKLCredentials()
    _ = generatedStore.store.write("generated-access", SIMKLTokenSlots.access(namespace))
    _ = generatedStore.store.write(String(expiry), SIMKLTokenSlots.expiry(namespace))
    let generatedSessionAccount = SIMKLTokenSlots.session(namespace)
    generatedStore.failNextWriteAfterPersist(containing: generatedSessionAccount)
    let generatedRecorder = SIMKLPublicationRecorder()
    let generatedObserver = "simkl-generated-session-restart-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: generatedObserver) { generatedRecorder.append($0) }
    let firstGeneratedAuth = SIMKLAuth(credentials: generatedStore.store)
    let firstGenerated = await firstGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let rawGeneratedSession: String? = {
        guard case let .value(raw) = generatedStore.durableValue(generatedSessionAccount) else { return nil }
        return raw
    }()
    let pendingGeneratedIntent = rawGeneratedSession.map {
        generatedStore.store.certifiedRead(SIMKLTokenSlots.publication(namespace)) == .value("pending:\($0)")
    } == true
    let generatedSessionBeforeRestart = await firstGeneratedAuth.sessionID
    let failedClosedBeforeRestart = firstGenerated == .failure
        && generatedStore.store.certifiedRead(generatedSessionAccount) == .failure
        && generatedSessionBeforeRestart == nil
        && generatedRecorder.snapshot().isEmpty
    let restartedGeneratedAuth = SIMKLAuth(credentials: generatedStore.store)
    let retriedGenerated = await restartedGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let generatedSessionFailAfterPersistRetried = rawGeneratedSession.map { raw in
        retriedGenerated == .success
            && pendingGeneratedIntent
            && failedClosedBeforeRestart
            && generatedStore.store.certifiedRead(generatedSessionAccount) == .value(raw)
            && generatedStore.store.certifiedRead(SIMKLTokenSlots.publication(namespace)) == .missing
            && generatedRecorder.snapshot() == [raw]
    } == true
    SIMKLAuthBoundary.removeObserver(key: generatedObserver)

    let missingGeneratedStore = MemorySIMKLCredentials()
    _ = missingGeneratedStore.store.write("missing-generated-access", SIMKLTokenSlots.access(namespace))
    _ = missingGeneratedStore.store.write(String(expiry), SIMKLTokenSlots.expiry(namespace))
    missingGeneratedStore.failNextWriteAfterPersistMissing(containing: generatedSessionAccount)
    let missingGeneratedRecorder = SIMKLPublicationRecorder()
    let missingGeneratedObserver = "simkl-generated-session-missing-restart-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: missingGeneratedObserver) { missingGeneratedRecorder.append($0) }
    let firstMissingGeneratedAuth = SIMKLAuth(credentials: missingGeneratedStore.store)
    let firstMissingGenerated = await firstMissingGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let preparedMissingGeneratedSession: String? = {
        guard case let .value(rawIntent) = missingGeneratedStore.store.certifiedRead(
            SIMKLTokenSlots.publication(namespace)
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
    let restartedMissingGeneratedAuth = SIMKLAuth(credentials: missingGeneratedStore.store)
    let retriedMissingGenerated = await restartedMissingGeneratedAuth.finalizeLegacyMigration(ownerCapture: capture)
    let missingGeneratedSessionAfterRestart = await restartedMissingGeneratedAuth.sessionID
    let generatedSessionFailBeforePersistRetried = preparedMissingGeneratedSession.map { prepared in
        missingGeneratedFailedClosed
            && retriedMissingGenerated == .success
            && missingGeneratedStore.store.certifiedRead(generatedSessionAccount) == .value(prepared)
            && missingGeneratedStore.store.certifiedRead(SIMKLTokenSlots.publication(namespace)) == .missing
            && missingGeneratedSessionAfterRestart?.rawValue == prepared
            && missingGeneratedRecorder.snapshot() == [prepared]
    } == true
    SIMKLAuthBoundary.removeObserver(key: missingGeneratedObserver)

    let mismatchStore = MemorySIMKLCredentials()
    _ = mismatchStore.store.write("mismatch-access", SIMKLTokenSlots.access(namespace))
    _ = mismatchStore.store.write(String(expiry), SIMKLTokenSlots.expiry(namespace))
    let expectedSession = UUID().uuidString.lowercased()
    _ = mismatchStore.store.write(
        "pending:\(expectedSession)",
        SIMKLTokenSlots.publication(namespace)
    )
    mismatchStore.failNextWriteAfterPersist(
        containing: generatedSessionAccount,
        persistedValue: "different-raw-session"
    )
    _ = mismatchStore.store.write(expectedSession, generatedSessionAccount)
    let mismatchRecorder = SIMKLPublicationRecorder()
    let mismatchObserver = "simkl-generated-session-mismatch-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: mismatchObserver) { mismatchRecorder.append($0) }
    let mismatchAuth = SIMKLAuth(credentials: mismatchStore.store)
    let mismatchResult = await mismatchAuth.finalizeLegacyMigration(ownerCapture: capture)
    let generatedSessionMismatchClosed = mismatchResult == .failure
        && mismatchStore.store.certifiedRead(generatedSessionAccount) == .failure
        && mismatchStore.durableValue(generatedSessionAccount) == .value("different-raw-session")
        && mismatchStore.store.certifiedRead(SIMKLTokenSlots.publication(namespace)) == .value("pending:\(expectedSession)")
        && mismatchStore.store.certifiedRead(SIMKLTokenSlots.active(namespace)) == .missing
        && mismatchStore.store.certifiedRead(SIMKLTokenSlots.candidate(namespace)) == .missing
        && mismatchRecorder.snapshot().isEmpty
    SIMKLAuthBoundary.removeObserver(key: mismatchObserver)
    Keychain.clear()
    await MainActor.run { _ = CredentialScopeRegistry.shared.bind(originalScope) }
    return (
        sessionlessFinalized,
        existingSessionPreserved,
        passiveStayedPure,
        writeFailureRetried,
        readbackFailureRetried,
        generatedSessionFailAfterPersistRetried,
        generatedSessionFailBeforePersistRetried,
        generatedSessionMismatchClosed
    )
}

private enum SIMKLAsyncOutcome: Equatable {
    case value(String)
    case cancelled
    case sessionChanged
    case otherFailure
}

private func captureSIMKLOutcome(_ operation: @escaping @Sendable () async throws -> String) async -> SIMKLAsyncOutcome {
    do {
        return .value(try await operation())
    } catch is CancellationError {
        return .cancelled
    } catch let error as SIMKLError where error == .sessionChanged {
        return .sessionChanged
    } catch {
        return .otherFailure
    }
}

private struct SIMKLCancelledPollResult {
    let outcome: SIMKLAsyncOutcome
    let finalSessionAbsent: Bool
    let finalTupleAbsent: Bool
    let activePointerMissing: Bool
    let publicationMissing: Bool
    let noBoundaryPublication: Bool

    static let failed = SIMKLCancelledPollResult(
        outcome: .otherFailure,
        finalSessionAbsent: false,
        finalTupleAbsent: false,
        activePointerMissing: false,
        publicationMissing: false,
        noBoundaryPublication: false
    )
}

private func testSIMKLCancelledAuthorizedPollFailsClosed() async -> SIMKLCancelledPollResult {
    let store = MemorySIMKLCredentials()
    let auth = makeConfiguredSIMKLAuth(store: store)
    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"user_code":"cancel-pin","verification_url":"https://fixture.invalid/verify","expires_in":600,"interval":1}
        """
    )
    guard let pin = try? await auth.requestPin() else { return .failed }

    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-cancelled-poll-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { SIMKLAuthBoundary.removeObserver(key: observer) }

    let gate = SIMKLHTTPRequestGate()
    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: #"{"result":"OK","access_token":"cancelled-poll-access"}"#,
        gate: gate
    )
    let polling = Task {
        await captureSIMKLOutcome {
            guard case let .authorized(token) = try await auth.poll(userCode: pin.userCode) else {
                throw SIMKLError.decoding
            }
            return token
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
    return SIMKLCancelledPollResult(
        outcome: outcome,
        finalSessionAbsent: finalSession == nil,
        finalTupleAbsent: finalTokens == nil,
        activePointerMissing: store.store.certifiedRead(SIMKLTokenSlots.active(namespace)) == .missing,
        publicationMissing: store.store.certifiedRead(SIMKLTokenSlots.publication(namespace)) == .missing,
        noBoundaryPublication: recorder.snapshot().isEmpty
    )
}

private struct SIMKLCancelledDrainResult {
    let setupFailure: String?
    let outcome: SIMKLAsyncOutcome
    let finalSessionMatchesA: Bool
    let finalTupleMatchesA: Bool
    let activePointerPresent: Bool
    let publicationMissing: Bool
    let noBoundaryPublication: Bool

    static func failed(_ phase: String) -> SIMKLCancelledDrainResult { SIMKLCancelledDrainResult(
        setupFailure: phase,
        outcome: .otherFailure,
        finalSessionMatchesA: false,
        finalTupleMatchesA: false,
        activePointerPresent: false,
        publicationMissing: false,
        noBoundaryPublication: false
    ) }
}

private func testSIMKLCancelledPollDuringBoundaryDrainFailsClosed() async -> SIMKLCancelledDrainResult {
    let store = MemorySIMKLCredentials()
    let (drainStream, drainContinuation) = AsyncStream<Void>.makeStream()
    let auth = makeConfiguredSIMKLAuth(
        store: store,
        sessionWriteDrainObserver: {
            drainContinuation.yield(())
            drainContinuation.finish()
        }
    )
    await adoptSIMKL(auth, label: "cancel-drain-A")
    guard let sessionA = await auth.sessionID else { return .failed("adopt A") }

    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"user_code":"cancel-drain-pin","verification_url":"https://fixture.invalid/verify","expires_in":600,"interval":1}
        """
    )
    guard let pin = try? await auth.requestPin() else { return .failed("request PIN") }

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

    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-cancelled-drain-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { SIMKLAuthBoundary.removeObserver(key: observer) }

    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: #"{"result":"OK","access_token":"cancel-drain-B-access"}"#
    )
    let polling = Task {
        await captureSIMKLOutcome {
            guard case let .authorized(token) = try await auth.poll(userCode: pin.userCode) else {
                throw SIMKLError.decoding
            }
            return token
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
    return SIMKLCancelledDrainResult(
        setupFailure: nil,
        outcome: outcome,
        finalSessionMatchesA: finalSession == sessionA,
        finalTupleMatchesA: finalTokens?.access == "cancel-drain-A-access",
        activePointerPresent: {
            if case .value = store.store.certifiedRead(SIMKLTokenSlots.active(namespace)) { return true }
            return false
        }(),
        publicationMissing: store.store.certifiedRead(SIMKLTokenSlots.publication(namespace)) == .missing,
        noBoundaryPublication: recorder.snapshot().isEmpty
    )
}

private struct SIMKLPostCommitCancellationResult {
    let setupFailure: String?
    let outcome: SIMKLAsyncOutcome
    let oneCurrentTuple: Bool
    let oneCurrentSession: Bool
    let onePublication: Bool

    static func failed(_ phase: String) -> SIMKLPostCommitCancellationResult {
        SIMKLPostCommitCancellationResult(
            setupFailure: phase,
            outcome: .otherFailure,
            oneCurrentTuple: false,
            oneCurrentSession: false,
            onePublication: false
        )
    }
}

/// The synchronous store hook runs after the precommit cancellation guard. Only the polling task is
/// cancelled while the write is held, and the actor's login invalidation is delayed until the result.
private func testSIMKLPostCommitCancellationLinearizesAuthorization() async -> SIMKLPostCommitCancellationResult {
    let store = MemorySIMKLCredentials()
    let auth = makeConfiguredSIMKLAuth(store: store)
    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: """
        {"user_code":"postcommit-pin","verification_url":"https://fixture.invalid/verify","expires_in":600,"interval":1}
        """
    )
    guard let pin = try? await auth.requestPin() else {
        return .failed("request PIN")
    }

    let gate = SIMKLStageWriteGate()
    store.installWriteHook { gate.observe($0) }
    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-postcommit-cancellation-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { SIMKLAuthBoundary.removeObserver(key: observer) }

    SIMKLFixtureURLProtocol.fixture.set(
        status: 200,
        json: #"{"result":"OK","access_token":"postcommit-access"}"#
    )
    let polling = Task {
        await captureSIMKLOutcome {
            try await auth.pollForToken(userCode: pin.userCode, interval: 1, expiresIn: 60)
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
    if case .value = store.store.certifiedRead(SIMKLTokenSlots.active(namespace)) {
        activePointerPresent = true
    } else {
        activePointerPresent = false
    }
    await auth.cancelLoginAttempt()
    return SIMKLPostCommitCancellationResult(
        setupFailure: nil,
        outcome: outcome,
        oneCurrentTuple: tokens?.access == "postcommit-access" && activePointerPresent,
        oneCurrentSession: session != nil,
        onePublication: publications.count == 1 && publications.first == session?.rawValue
    )
}

/// A failed clear keeps the durable/current provider boundary live. The callback models the UI reset that
/// must remain unfired until the exact Bool result authorizes it.
private func testSIMKLDurableSignOutDefersUIResetUntilSuccess() async -> Bool {
    let store = MemorySIMKLCredentials()
    let auth = SIMKLAuth(credentials: store.store)
    await adoptSIMKL(auth, label: "signout-durable")
    let namespace = CredentialScopeRegistry.shared.currentNamespace()
    guard let session = await auth.sessionID,
          let activePointer = store.value(SIMKLTokenSlots.active(namespace)) else { return false }

    let recorder = SIMKLPublicationRecorder()
    let observer = "simkl-signout-durable-\(UUID().uuidString)"
    SIMKLAuthBoundary.observe(key: observer) { recorder.append($0) }
    defer { SIMKLAuthBoundary.removeObserver(key: observer) }

    let activeAccount = SIMKLTokenSlots.active(namespace)
    store.installDurableReadHook { account, result in
        account == activeAccount ? .failure : result
    }
    var resetCallbacks = 0
    let first = await auth.signOut()
    if first { resetCallbacks += 1 }
    store.installDurableReadHook { _, result in result }
    let sessionAfterFailure = await auth.sessionID
    let tokensAfterFailure = await auth.syncableTokens()
    let retainedAfterFailure = !first
        && resetCallbacks == 0
        && sessionAfterFailure == session
        && tokensAfterFailure?.access == "signout-durable-access"
        && store.durableValue(activeAccount) == .value(activePointer)
        && recorder.snapshot().isEmpty

    let retry = await auth.signOut()
    if retry { resetCallbacks += 1 }
    let sessionAfterRetry = await auth.sessionID
    let tokensAfterRetry = await auth.syncableTokens()
    let clearedOnRetry = retry
        && resetCallbacks == 1
        && sessionAfterRetry == nil
        && tokensAfterRetry == nil
        && store.store.certifiedRead(SIMKLTokenSlots.active(namespace)) == .missing
        && recorder.snapshot() == ["nil"]
    return retainedAfterFailure && clearedOnRetry
}

private func testSIMKLCancellationSourceContract() -> Bool {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SourcesShared/SIMKLAuth.swift")
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return false }
    guard let pollStart = source.range(of: "private func poll(\n        userCode: String,"),
          let pollEnd = source.range(
              of: "    /// Run the full polling loop",
              range: pollStart.upperBound..<source.endIndex
          ),
          let loopStart = source.range(of: "func pollForToken(userCode: String"),
          let loopEnd = source.range(
              of: "    /// Stop the currently displayed PIN flow",
              range: loopStart.upperBound..<source.endIndex
          ) else { return false }
    let poll = String(source[pollStart.lowerBound..<pollEnd.lowerBound])
    let loop = String(source[loopStart.lowerBound..<loopEnd.lowerBound])
    guard let installed = poll.range(of: "let installed = await performCredentialBoundary"),
          let precommit = poll.range(of: "guard !Task.isCancelled"),
          let persist = poll.range(of: "persisted = replaceCredentialsWithNewSession"),
          let authorized = poll.range(of: "return .authorized(token)"),
          let failureGuard = poll.range(
              of: "guard installed, persisted else {\n                try Task.checkCancellation()\n                throw SIMKLError.transport(\"SIMKL credential persistence failed\")\n            }"
          ) else { return false }
    let postFailure = String(poll[failureGuard.upperBound..<authorized.lowerBound])
    let failurePathChecksCancellation = failureGuard.lowerBound < authorized.lowerBound
    let directLinearization = installed.lowerBound < precommit.lowerBound
        && precommit.lowerBound < persist.lowerBound
        && failurePathChecksCancellation
        && !postFailure.contains("try Task.checkCancellation()")
    let wrapperLinearization = loop.contains(
        "if case .authorized(let token) = result { return token }\n            try Task.checkCancellation()"
    )
    return source.contains("guard !Task.isCancelled")
        && directLinearization
        && wrapperLinearization
        && source.contains("catch is CancellationError")
}

@main
struct SIMKLSessionSecurityTestRunner {
    @MainActor
    static func main() async {
        var loginAuthority = SIMKLLoginAttemptAuthority()
        let loginA = loginAuthority.begin()
        loginAuthority.register(code: "pin-A", generation: loginA)
        expect(loginAuthority.owns(code: "pin-A", generation: loginA),
               "the active SIMKL PIN owns its login generation")
        let loginB = loginAuthority.begin()
        loginAuthority.register(code: "pin-B", generation: loginB)
        expect(!loginAuthority.owns(code: "pin-A", generation: loginA),
               "starting a replacement SIMKL login invalidates the old PIN")
        expect(loginAuthority.owns(code: "pin-B", generation: loginB),
               "the replacement SIMKL PIN owns only the new generation")
        loginAuthority.invalidate()
        expect(!loginAuthority.owns(code: "pin-B", generation: loginB),
               "an account boundary invalidates an in-flight SIMKL login")

        let cancelledPoll = await testSIMKLCancelledAuthorizedPollFailsClosed()
        expect(cancelledPoll.outcome == .cancelled,
               "SIMKL transport-gated poll maps task cancellation distinctly")
        expect(cancelledPoll.finalSessionAbsent,
               "SIMKL cancelled first-login poll creates no session")
        expect(cancelledPoll.finalTupleAbsent,
               "SIMKL cancelled first-login poll creates no credential tuple")
        expect(cancelledPoll.activePointerMissing,
               "SIMKL cancelled first-login poll creates no active pointer")
        expect(cancelledPoll.publicationMissing,
               "SIMKL cancelled first-login poll creates no publication marker")
        expect(cancelledPoll.noBoundaryPublication,
               "SIMKL cancelled first-login poll emits no boundary publication")

        let cancelledDrain = await testSIMKLCancelledPollDuringBoundaryDrainFailsClosed()
        expect(cancelledDrain.setupFailure == nil,
               "SIMKL cancellation race reached its exact drain checkpoint (\(cancelledDrain.setupFailure ?? "complete"))")
        expect(cancelledDrain.outcome == .cancelled,
               "SIMKL drain-gated poll maps task cancellation distinctly")
        expect(cancelledDrain.finalSessionMatchesA,
               "SIMKL cancelled drain resumes with A session unchanged")
        expect(cancelledDrain.finalTupleMatchesA,
               "SIMKL cancelled drain resumes with A credential tuple unchanged")
        expect(cancelledDrain.activePointerPresent,
               "SIMKL cancelled drain preserves A's certified active pointer")
        expect(cancelledDrain.publicationMissing,
               "SIMKL cancelled drain leaves no pending publication marker")
        expect(cancelledDrain.noBoundaryPublication,
               "SIMKL cancelled drain emits no replacement boundary publication")
        let postCommitCancellation = await testSIMKLPostCommitCancellationLinearizesAuthorization()
        expect(postCommitCancellation.setupFailure == nil,
               "SIMKL postcommit cancellation race reached its exact synchronous write checkpoint (\(postCommitCancellation.setupFailure ?? "complete"))")
        expect(postCommitCancellation.outcome == .value("postcommit-access"),
               "SIMKL cancellation after the precommit guard returns the installed authorization")
        expect(postCommitCancellation.oneCurrentTuple,
               "SIMKL postcommit cancellation leaves one current durable credential tuple")
        expect(postCommitCancellation.oneCurrentSession,
               "SIMKL postcommit cancellation leaves one current session")
        expect(postCommitCancellation.onePublication,
               "SIMKL postcommit cancellation publishes the installed session exactly once")
        expect(testSIMKLCancellationSourceContract(),
               "SIMKL source keeps fail-closed precommit fences while authorization linearizes after commit")
        expect(await testSIMKLDurableSignOutDefersUIResetUntilSuccess(),
               "SIMKL reports a failed durable clear without firing the UI reset, then clears and publishes once on retry")

        let replayAuth = makeSIMKLAuth()
        await adoptSIMKL(replayAuth, label: "stable")
        let stableSession = await replayAuth.sessionID
        await adoptSIMKL(replayAuth, label: "stable")
        expect(await replayAuth.sessionID == stableSession,
               "an identical SIMKL credential replay preserves its session")
        await adoptSIMKL(replayAuth, label: "replacement")
        expect(await replayAuth.sessionID != stableSession,
               "a changed SIMKL credential rotates the account session")

        expect(await testDelayedAIntentCannotUseB(),
               "a delayed SIMKL A mutation cannot use B credentials")

        let boundary = await testPendingBoundaryAdmissionAndOrdering()
        expect(boundary.pendingObserved,
               "SIMKL announces a pending boundary while A drains")
        expect(boundary.sessionWhileDraining != nil,
               "SIMKL retains A only for the already-authorized write")
        expect(!boundary.admittedSecondWrite,
               "SIMKL rejects a new A write while a boundary is pending")
        expect(boundary.firstToken == "A-access",
               "the leased SIMKL A write completes with A credentials")
        expect(boundary.finalToken == "B-access",
               "serialized SIMKL boundaries deterministically install B")
        expect(boundary.finalSession != boundary.sessionWhileDraining,
               "SIMKL B receives a distinct account session")

        expect(await testOwnerSwitchMidAwaitAdoption(),
               "a SIMKL adoption captured for A cannot write after the owner switches to B")
        expect(await testSIMKLOwnerBindCannotOvertakePreDispatchMutation(),
               "SIMKL owner bind cannot overtake a staged credential mutation before dispatch")

        let providerStageProof = await testSIMKLProviderRecoveryRequiresDurableStageProof()
        expect(providerStageProof.mismatchedSelectedClosed,
               "SIMKL provider recovery rejects mismatched raw selected-stage bytes without durable tuple proof")
        expect(providerStageProof.nilActiveRetryPromotedOnce,
               "SIMKL public adoption retry promotes an exact nil-active pending candidate once")
        expect(providerStageProof.manifestFailAfterPersistRetried,
               "SIMKL public adoption retry removes an uncertain pre-stage manifest and restages exactly")

        expect(await testSIMKLOutboxFencesAndDispatchingRepair(),
               "SIMKL pending and dispatching outboxes fence passive, bound, unbound, and static credential surfaces until sign-out repair")
        expect(await testSIMKLPublicationIntentAndSameSessionRecovery(),
               "SIMKL writes publication intent before promotion, retains missing-intent B, and recovers a same-session final-delete fault")
        expect(await testSIMKLPinPollPersistsCredentialBoundary(),
               "SIMKL PIN poll persists and publishes its credential boundary through the production path")

        let replacement = await testSIMKLReplacementKeepsTheLastCertifiedTuple()
        expect(replacement.mixedTuplePreserved,
               "SIMKL failed delete plus failed replacement write preserves the complete A tuple")
        expect(replacement.mixedTupleRetry,
               "SIMKL mixed-tuple failure retries to one complete B tuple")
        expect(replacement.stagedWriteFailurePreserved,
               "SIMKL staged slot write failure does not replace the active tuple")
        expect(replacement.stagedWriteRetry,
               "SIMKL staged slot write failure is retryable")
        expect(replacement.activationFailurePreserved,
               "SIMKL activation-pointer failure does not replace the active tuple")
        expect(replacement.activationRetry,
               "SIMKL activation-pointer failure is retryable")
        expect(replacement.stagedReadFailurePreserved,
               "SIMKL staged durable read failure does not replace the active tuple")
        expect(replacement.stagedReadRetry,
               "SIMKL staged durable read failure is retryable")

        let hostile = await testSIMKLCredentialTransactionHostiles()
        expect(hostile.exactStaging,
               "SIMKL stages one complete tuple and activates one exact durable pointer")
        expect(hostile.pointerCandidate,
               "SIMKL fail-after-persist pointer readback classifies the candidate without rollback")
        expect(hostile.pointerOld,
               "SIMKL failed pointer write classified as old preserves the certified tuple")
        expect(hostile.pointerUnknown,
               "SIMKL unknown pointer readback fails closed without a rollback guess")
        expect(hostile.candidateRetention,
               "SIMKL retains the candidate marker until its exact staged tuple is cleaned")
        expect(hostile.legacyPreRecovery,
               "SIMKL legacy pre marker with no active pointer cleans its old stage before the marker")
        expect(hostile.repairMarkerGate,
               "SIMKL legacy session repair requires durable absence of active, cleanup, and candidate markers")
        expect(hostile.exactDurableReads,
               "SIMKL token and session reads use one exact durable selected tuple")
        expect(hostile.postCleanupRetry,
               "SIMKL post-activation cleanup failure suppresses publication and restart retries exact B")
        expect(hostile.postMirrorRetry,
               "SIMKL post-pointer session mirror failure suppresses currentSessionID until exact B retry")
        expect(hostile.signOutRetry,
               "SIMKL sign-out cleans active/candidate/pre identities before publishing nil and retains retry state")
        expect(hostile.malformedPointerClosed,
               "SIMKL malformed pointer identities fail closed")
        expect(testSIMKLUnknownNilPointerRecovery(),
               "SIMKL unknown nil-pointer recovery retains every stage and marker without certifying a mirror")
        let stalePublication = await testSIMKLStalePublicationBarriers()
        expect(stalePublication.pendingDrained,
               "SIMKL drains a matching pending publication before replacing the active tuple")
        expect(stalePublication.acknowledgedFinalized,
               "SIMKL finalizes a matching acknowledged publication before replacing the active tuple")
        expect(stalePublication.retryAfterMismatch,
               "SIMKL retains a mismatched publication barrier and retries it safely after restart")
        expect(stalePublication.activeCandidateMismatchRetained,
               "SIMKL active-candidate recovery retains a mismatched publication marker and tuple")
        expect(await testSIMKLFinalMarkerDeleteRestoresIdentity(),
               "SIMKL uncertain final-marker deletion restores a discoverable identity for restart cleanup")
        expect(await testSIMKLValidTokenSerializesOwnerSwitch(),
               "SIMKL validToken(for:) serializes an owner switch without recapturing B")
        let publicationBoundaryRaces = await testSIMKLPublicationBoundaryRaces()
        expect(publicationBoundaryRaces.signOutOrdered,
               "SIMKL observer-thread boundary reentrancy fails closed and queued sign-out still clears exactly once")
        expect(publicationBoundaryRaces.ownerSwitchOrdered,
               "SIMKL owner bind does not flip under a live publication and a queued boundary keeps MainActor live")
        expect(await testSIMKLCrossInstanceClearWaitsForDispatch(),
               "SIMKL clear from a second auth instance waits for the shared dispatch lease and publishes nil last")
        let publicPointerRecovery = await testSIMKLPublicRetryRecoversActivePointer()
        expect(publicPointerRecovery.publicRetry,
               "SIMKL public adoption retry recovers an invalidated active pointer before replay")
        expect(publicPointerRecovery.malformedClosed,
               "SIMKL public retry rejects malformed raw pointer evidence without publication")
        expect(publicPointerRecovery.mismatchedClosed,
               "SIMKL public retry rejects a canonical pointer with no certified tuple stages")
        let publicCandidateRecovery = await testSIMKLPublicRetryAfterCandidatePersistenceFailures()
        expect(publicCandidateRecovery.activePointer,
               "SIMKL public mutation retry recovers an uncertain active-pointer write")
        expect(publicCandidateRecovery.cleanupStage,
               "SIMKL public mutation retry recovers an uncertain cleanup-stage write")
        expect(publicCandidateRecovery.cleanupMarker,
               "SIMKL public mutation retry recovers an uncertain cleanup-marker write")
        expect(publicCandidateRecovery.mirror,
               "SIMKL public mutation retry recovers an uncertain mirror write")
        expect(publicCandidateRecovery.missingIntentClosed,
               "SIMKL public mutation retry keeps a selected candidate closed when its intent is missing")
        expect(testSIMKLActiveCandidateFinalizesBeforeNextPublication(),
               "SIMKL finalizes published B before a failed C stage and preserves certified B")
        let candidateStageRecovery = testSIMKLCandidateStageFailAfterPersistRecovery()
        expect(candidateStageRecovery.allSlotsRecovered,
               "SIMKL recovery enumerates and certifies every candidate stage after fail-after-persist")
        expect(candidateStageRecovery.mismatchedClosed,
               "SIMKL mismatched candidate stage evidence remains closed without publication")
        expect(candidateStageRecovery.unbackedClosed,
               "SIMKL unbacked candidate stage evidence is deleted and exact input is restaged without raw publication")
        let emptyCandidateStageRecovery = await testSIMKLEmptyCandidateStageFailAfterPersistRecovery()
        expect(emptyCandidateStageRecovery.allSlotsRecovered,
               "SIMKL empty first-login retry recovers every fail-after-persist staged slot through public adoption")
        expect(emptyCandidateStageRecovery.malformedClosed,
               "SIMKL malformed first-login candidate evidence remains closed without publication")
        expect(emptyCandidateStageRecovery.unbackedClosed,
               "SIMKL unbacked first-login candidate evidence remains closed without publication")
        expect(testSIMKLUncertainDeleteRawMissingRecovery(),
               "SIMKL certified failure plus raw marker/stage absence retries deletion to certified absence")
        expect(testSIMKLMirrorFailAfterPersistRecovery(),
               "SIMKL fail-after-persist mirror bytes are repaired from exact recovery evidence before authority reuse")
        expect(await testSIMKLClearDualReadRecovery(),
               "SIMKL sign-out recovers an uncertain outbox delete before publishing the nil boundary")
        expect(testSIMKLCertifiedKeychainAdapter(),
               "SIMKL runtime adapters use certified Keychain reads and reserve raw reads for legacy/recovery")

        let legacyFinalization = await testSIMKLExplicitLegacyMigrationFinalization()
        expect(legacyFinalization.sessionlessFinalized,
               "SIMKL explicitly finalizes a sessionless claimed legacy pair exactly once")
        expect(legacyFinalization.existingSessionPreserved,
               "SIMKL claims and preserves an existing legacy session during explicit finalization")
        expect(legacyFinalization.passiveStayedPure,
               "SIMKL passive legacy surfaces remain closed without writing or publishing")
        expect(legacyFinalization.writeFailureRetried,
               "SIMKL legacy finalization preserves and retries after a staged write failure")
        expect(legacyFinalization.readbackFailureRetried,
               "SIMKL legacy finalization preserves and retries after a staged readback failure")
        expect(legacyFinalization.generatedSessionFailAfterPersistRetried,
               "SIMKL legacy finalization restart recovers only the generated session proven by its pending intent")
        expect(legacyFinalization.generatedSessionFailBeforePersistRetried,
               "SIMKL legacy finalization restart rewrites a missing generated session proven by its pending intent")
        expect(legacyFinalization.generatedSessionMismatchClosed,
               "SIMKL legacy finalization rejects raw generated-session bytes that differ from the pending intent")

        let firstBoundaryCounter = SIMKLBoundaryCounter()
        let secondBoundaryCounter = SIMKLBoundaryCounter()
        SIMKLAuthBoundary.observe(key: "simkl-boundary-removal-first") { _ in
            firstBoundaryCounter.increment()
        }
        SIMKLAuthBoundary.observe(key: "simkl-boundary-removal-second") { _ in
            secondBoundaryCounter.increment()
        }
        SIMKLAuthBoundary.publish(nil)
        SIMKLAuthBoundary.removeObserver(key: "simkl-boundary-removal-first")
        SIMKLAuthBoundary.publish(nil)
        expect(firstBoundaryCounter.snapshot() == 1,
               "removing one SIMKL boundary observer stops only that observer")
        expect(secondBoundaryCounter.snapshot() == 2,
               "a remaining SIMKL boundary observer survives another observer's removal")
        SIMKLAuthBoundary.removeObserver(key: "simkl-boundary-removal-second")

        if failures.isEmpty {
            print("PASS: \(checks) SIMKL session security checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
