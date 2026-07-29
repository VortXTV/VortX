// Standalone adversarial tests for Trakt auth session identity and write leases.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/trakt-session-security \
//     app/SourcesShared/TraktScrobbleProgressPolicy.swift \
//     app/SourcesShared/TraktAuth.swift \
//     app/Tests/TraktSessionSecurityTests.swift && /tmp/trakt-session-security

import Foundation

/// Production dependencies are replaced with isolated test seams.
enum Keychain {
    static func string(_ account: String) -> String? { nil }
    static func set(_ value: String?, for account: String) {}
}

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {}
}

struct TraktDeviceCode: Codable, Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
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

    var store: TraktCredentialStore {
        TraktCredentialStore(
            read: { key in self.read(key) },
            write: { value, key in self.write(value, key) }
        )
    }

    private func read(_ key: String) -> String? {
        lock.lock()
        let value = values[key]
        lock.unlock()
        return value
    }

    private func write(_ value: String?, _ key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}

final class HTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = Data()

    func set(status: Int, json: String = "") {
        lock.lock()
        self.status = status
        body = Data(json.utf8)
        lock.unlock()
    }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.lock()
        let status = self.status
        let body = body
        lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://fixture.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, body)
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

@MainActor private var failures: [String] = []
@MainActor private var checks = 0

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

private func makeAuth(store: MemoryCredentials) -> TraktAuth {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    return TraktAuth(
        session: URLSession(configuration: configuration),
        credentials: store.store,
        configuration: TraktAuthConfiguration(
            clientID: "test-client",
            clientSecret: "test-secret",
            apiBase: "https://fixture.invalid"
        )
    )
}

private func adoptLiveToken(_ auth: TraktAuth, label: String) async {
    await auth.adoptTokens(
        access: "\(label)-access",
        refresh: "\(label)-refresh",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3600
    )
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
    FixtureURLProtocol.fixture.set(status: 401)

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
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "expires_in": 3600,
              "token_type": "bearer",
              "created_at": \(now)
            }
            """
        )
        let refreshed = try? await refreshAuth.validToken()
        expect(refreshed == "new-access", "token refresh returns the rotated access token")
        expect(await refreshAuth.sessionID == beforeRefresh,
               "token refresh preserves the authenticated session id")

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

        // A terminal refresh 401 clears the session and publishes the boundary before returning.
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
        FixtureURLProtocol.fixture.set(status: 401)
        _ = try? await lossAuth.validToken()
        expect(await lossAuth.sessionID == nil,
               "automatic refresh 401 removes the complete auth session")
        expect(!visibility.snapshot(),
               "automatic refresh 401 publishes synchronous private-state invalidation")

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

        if failures.isEmpty {
            print("PASS: \(checks) Trakt session security checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
