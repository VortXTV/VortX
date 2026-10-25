// Control-only fixture. Root's runner inserts the exact production QR types/methods
// and auth-generation helpers. Crypto, HTTP, credential-owner binding and adoption
// are inert controlled boundaries; this is NOT Keychain/crypto/network/UI proof.
import Foundation

private enum Curve25519 {
    enum KeyAgreement {
        struct PrivateKey { let id = UUID() }
    }
}
private enum PairingCrypto {
    struct Ephemeral {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyBase64URL = "fixture-only-public"
    }
    static func newEphemeral() -> Ephemeral { Ephemeral() }
    static func unwrapDataKey(wrapped: String, holderPublicKey: String,
                              using: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        wrapped == "fixture-only-wrapped" && holderPublicKey == "fixture-only-claim"
            ? Data(repeating: 7, count: 32) : nil
    }
}
@MainActor private enum ProcessInfo {
    struct Uptime { var systemUptime: TimeInterval }
    static var processInfo = Uptime(systemUptime: 100)
}
@MainActor private final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() {
        released = true
        let pending = continuations; continuations = []
        pending.forEach { $0.resume() }
    }
}
@MainActor private final class CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: Int }
    var generation = 1
    func capture() -> Capture { Capture(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}

@MainActor private final class VortXSyncManager {
    private let credentialAuthority = CredentialScopeRegistry()
    private var authOperationGeneration: UInt64 = 0
    private var qrOperation: QrJoinOperation?
    /* PRODUCTION_AUTH_CAPTURE */
    /* PRODUCTION_AUTH_GENERATION */
    /* PRODUCTION_QR */

    var requests: [String] = []
    var adoptions: [String] = []
    var startCount = 0
    var meStatuses: [Int] = []
    var startGate: Gate?
    var statusGate: Gate?
    var meGate: Gate?
    var bindGate: Gate?
    var malformedApproval = false
    var malformedAccount = false
    var afterStatus: (() -> Void)?
    var afterMe: (() -> Void)?

    private func cancelCredentialOwnerRetry() {}
    func supersede() { _ = beginCredentialOwnerIntent() }
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         auth: Bool = false, bearer: String? = nil,
                         credentialCapture: CredentialScopeRegistry.Capture? = nil) async -> (Int, [String: Any]?) {
        requests.append(path)
        if path == "/v1/qr/start" {
            startCount += 1; let number = startCount
            if let startGate { await startGate.wait() }
            return (200, ["pairingID": "fixture-\(number)", "code": "ABCDEFGH"])
        }
        if path.hasPrefix("/v1/qr/status?id=") {
            if let statusGate { await statusGate.wait() }
            afterStatus?()
            let payload = malformedApproval ? "{}" : "{\"claim\":\"fixture-only-claim\",\"wrapped\":\"fixture-only-wrapped\"}"
            return (200, ["token": "fixture-only-token", "payload": payload])
        }
        if path == "/v1/auth/me" {
            if let meGate { await meGate.wait() }
            afterMe?()
            let status = meStatuses.isEmpty ? 200 : meStatuses.removeFirst()
            return (status, malformedAccount ? [:] : ["account": ["id": "fixture-only-id", "email": "fixture.invalid", "username": "fixture"]])
        }
        return (500, nil)
    }
    // The actual adopter is a separate existing durability gate. This stand-in
    // deliberately changes the credential capture BEFORE suspending at bindGate,
    // reproducing the cancellation aperture without touching any account store.
    private func adopt(token: String, account: [String: Any], dataKey: Data,
                       expectedOperation: AuthOperationCapture? = nil) async -> Bool {
        guard let operation = expectedOperation, isCurrent(operation), !Task.isCancelled else { return false }
        guard !token.isEmpty, account["id"] as? String == "fixture-only-id",
              account["email"] is String, account["username"] is String,
              dataKey.count == 32 else { return false }
        credentialAuthority.generation += 1
        if let bindGate { await bindGate.wait() }
        guard operation.generation == authOperationGeneration, !Task.isCancelled else { return false }
        adoptions.append(token)
        return true
    }
}

@main private enum NativeQRJoinOwnershipTests {
    @MainActor private static var checks = 0
    @MainActor private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { print("FAIL \(message)"); exit(1) }
        print("PASS \(message)")
    }
    @MainActor private static func entered(_ gate: Gate) async {
        for _ in 0..<1000 {
            if gate.entered { return }
            await Task.yield()
        }
        check(false, "controlled effect must enter before schedule continues")
    }
    @MainActor static func main() async {
        do {
            let manager = VortXSyncManager(), gate = Gate(); manager.startGate = gate
            let old = Task { @MainActor in await manager.qrStart() }
            await entered(gate); old.cancel(); manager.startGate = nil
            let replacement = await manager.qrStart()!
            gate.release()
            check(await old.value == nil, "cancelled start cannot return a late session")
            check(await manager.qrPoll(replacement) == .signedIn(email: "fixture.invalid"),
                  "late start cleanup preserves replacement pairing")
        }
        do {
            let manager = VortXSyncManager()
            let a = await manager.qrStart()!, b = await manager.qrStart()!
            let before = manager.requests.count
            check(await manager.qrPoll(a) == .failed, "old session cannot borrow replacement auth operation")
            check(manager.requests.count == before, "old session rejected before destructive relay read")
            check(await manager.qrPoll(b) == .signedIn(email: "fixture.invalid"), "replacement pairing still works")
            let accepted = manager.requests.count
            check(await manager.qrPoll(b) == .failed, "completed pairing cannot adopt through ambient fallback")
            check(manager.requests.count == accepted && manager.adoptions.count == 1, "retired session makes no request or second adoption")
        }
        for transient in [0, 408, 429, 500, 503, 504] {
            let manager = VortXSyncManager(); manager.meStatuses = [transient, 200]
            let session = await manager.qrStart()!
            check(await manager.qrPoll(session) == .transportError, "transient /me status \(transient) remains retryable")
            check(manager.adoptions.isEmpty, "transient /me cannot publish signed-in state")
            check(await manager.qrPoll(session) == .signedIn(email: "fixture.invalid"), "same received approval survives /me retry \(transient)")
            check(manager.requests.filter { $0.hasPrefix("/v1/qr/status") }.count == 1,
                  "retry never re-reads already consumed approval \(transient)")
        }
        for rejected in [400, 401, 403] {
            let manager = VortXSyncManager(); manager.meStatuses = [rejected]
            let session = await manager.qrStart()!
            check(await manager.qrPoll(session) == .failed, "rejected /me status \(rejected) is terminal")
            let count = manager.requests.count
            check(await manager.qrPoll(session) == .failed && manager.requests.count == count,
                  "terminal rejection retires exact cached approval \(rejected)")
            check(manager.adoptions.isEmpty, "rejected account is never adopted")
        }
        do {
            let manager = VortXSyncManager(), gate = Gate(); manager.statusGate = gate
            let session = await manager.qrStart()!
            let first = Task { @MainActor in await manager.qrPoll(session) }
            await entered(gate)
            check(await manager.qrPoll(session) == .pending, "overlapping poll does not race the one-use delivery")
            check(manager.requests.filter { $0.hasPrefix("/v1/qr/status") }.count == 1,
                  "one destructive relay request per in-flight pairing")
            gate.release()
            check(await first.value == .signedIn(email: "fixture.invalid") && manager.adoptions.count == 1,
                  "original poll owns the only adoption")
        }
        do {
            let manager = VortXSyncManager(), gate = Gate(); manager.meGate = gate
            let a = await manager.qrStart()!
            let first = Task { @MainActor in await manager.qrPoll(a) }
            await entered(gate); manager.qrCancel(a)
            manager.meGate = nil
            let b = await manager.qrStart()!
            gate.release()
            check(await first.value == .failed && manager.adoptions.isEmpty, "late old /me cannot adopt after cancel and remint")
            manager.qrCancel(a)
            check(await manager.qrPoll(b) == .signedIn(email: "fixture.invalid"), "old cleanup cannot retire replacement pairing")
        }
        do {
            let manager = VortXSyncManager(), gate = Gate(); manager.bindGate = gate
            let session = await manager.qrStart()!
            let poll = Task { @MainActor in await manager.qrPoll(session) }
            await entered(gate); manager.qrCancel(session); gate.release()
            check(await poll.value == .failed && manager.adoptions.isEmpty,
                  "cancel after credential bind still revokes original auth generation")
        }
        do {
            let manager = VortXSyncManager(), gate = Gate(); manager.meGate = gate
            let session = await manager.qrStart()!
            let poll = Task { @MainActor in await manager.qrPoll(session) }
            await entered(gate); manager.supersede(); gate.release()
            check(await poll.value == .failed && manager.adoptions.isEmpty,
                  "new non-QR auth intent rejects old QR completion")
        }
        do {
            let manager = VortXSyncManager(); manager.malformedApproval = true
            let session = await manager.qrStart()!
            check(await manager.qrPoll(session) == .failed, "malformed wrapped approval is terminal")
            check(!manager.requests.contains("/v1/auth/me") && manager.adoptions.isEmpty,
                  "no account request or adoption before key unwrap succeeds")
        }
        do {
            let manager = VortXSyncManager(); manager.malformedAccount = true
            let session = await manager.qrStart()!
            check(await manager.qrPoll(session) == .failed && manager.adoptions.isEmpty,
                  "malformed account is terminal and cannot adopt")
        }
        for stage in ["before", "status", "me"] {
            ProcessInfo.processInfo.systemUptime = 100
            let manager = VortXSyncManager(), session = await manager.qrStart()!
            if stage == "before" { ProcessInfo.processInfo.systemUptime += 240 }
            if stage == "status" { manager.afterStatus = { ProcessInfo.processInfo.systemUptime += 240 } }
            if stage == "me" { manager.afterMe = { ProcessInfo.processInfo.systemUptime += 240 } }
            check(await manager.qrPoll(session) == .expired && manager.adoptions.isEmpty,
                  "monotonic pairing expiry rejects at \(stage) boundary")
            let before = manager.requests.count
            check(await manager.qrPoll(session) == .failed && manager.requests.count == before,
                  "expired approval is retired at \(stage) boundary")
        }
        do {
            ProcessInfo.processInfo.systemUptime = 100
            let manager = VortXSyncManager(); manager.meStatuses = [503]
            let session = await manager.qrStart()!
            check(await manager.qrPoll(session) == .transportError, "approved ciphertext retained only for bounded retry")
            ProcessInfo.processInfo.systemUptime += 240
            let before = manager.requests.count
            check(await manager.qrPoll(session) == .expired && manager.requests.count == before,
                  "cached approval also expires without another network request")
        }
        ProcessInfo.processInfo.systemUptime = 100
        print("PASS \(checks) actual-production QR control checks; inert crypto/HTTP/durability boundaries")
    }
}
