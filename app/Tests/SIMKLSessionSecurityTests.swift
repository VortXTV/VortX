// Standalone adversarial tests for SIMKL auth session identity and write leases.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/simkl-session-security \
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

enum Keychain {
    static func string(_ account: String) -> String? { nil }
    static func set(_ value: String?, for account: String) {}
}

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {}
}

final class MemorySIMKLCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var store: SIMKLCredentialStore {
        SIMKLCredentialStore(
            read: { key in self.read(key) },
            write: { value, key in self.write(value, key) }
        )
    }

    private func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    private func write(_ value: String?, _ key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
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

private func adoptSIMKL(_ auth: SIMKLAuth, label: String) async {
    await auth.adoptTokens(
        access: "\(label)-access",
        expiryUnix: Int(Date().timeIntervalSince1970) + 3_600
    )
}

private func waitForPendingBoundary(_ auth: SIMKLAuth) async -> Bool {
    for _ in 0..<1_000 {
        if await auth.isCredentialBoundaryPending { return true }
        await Task.yield()
    }
    return false
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
