import Foundation

private enum CredentialScopeRegistry {
    struct Capture: Equatable { let generation: Int }
}

@MainActor private final class FixtureAuthority {
    var generation = 1
    func capture() -> CredentialScopeRegistry.Capture { .init(generation: generation) }
}

/// Contract relay: encrypted backup storage accepts an insert or a strictly newer row revision.
/// It cannot merge the private document; the client must read and merge after a lost race.
@MainActor private final class BackupRelay {
    var revision: Int?
    var document: [String: Any]
    init(revision: Int?, document: [String: Any] = [:]) {
        self.revision = revision; self.document = document
    }
}

@MainActor private final class UploadHarness {
    private enum PushOutcome { case accepted(version: Int); case rejected(storedVersion: Int?); case upgradeRequired; case error }
    private let credentialAuthority = FixtureAuthority()
    let relay: BackupRelay
    var sent: [Int] = []
    var witnesses: [Int?] = []
    var plaintexts: [Data?] = []
    var acceptedCallbacks = 0
    var pendingApply = false
    var networkFailure = false
    var loseAcceptedResponse = false
    var upgradeRequired = false
    var mountCurrent = true
    var afterSending: (() -> Void)?
    var rejectedEcho: Int?
    var onRebuild: (() -> Void)?

    init(_ relay: BackupRelay) { self.relay = relay }
    private func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool {
        capture == credentialAuthority.capture()
    }
    private func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pendingApply }
    private func pushSyncDocAt(_ document: [String: Any], version: Int, baseRevision: Int?,
                               credentialCapture capture: CredentialScopeRegistry.Capture,
                               plaintextData: Data? = nil,
                               sourceIsCurrent: () -> Bool) async -> PushOutcome {
        guard isCurrent(capture), sourceIsCurrent(), !pendingApply else { return .error }
        sent.append(version)
        witnesses.append(baseRevision)
        plaintexts.append(plaintextData)
        if upgradeRequired { return .upgradeRequired }
        if networkFailure { return .error }
        if relay.revision != baseRevision { return .rejected(storedVersion: rejectedEcho ?? relay.revision) }
        relay.revision = version; relay.document = document
        afterSending?()
        if loseAcceptedResponse || !isCurrent(capture) || !sourceIsCurrent() { return .error }
        return .accepted(version: version)
    }
    func retire() { credentialAuthority.generation += 1 }

    func send(_ document: [String: Any], base: Int?, edit: [String: String],
              rebuildFails: Bool = false, plaintext: Data? = nil, rebuiltPlaintext: Data? = nil) async -> Bool {
        let capture = credentialAuthority.capture()
        let sourceIsCurrent = { [self] in mountCurrent }
        let rebuild = { [self] () async -> DerivedSyncDoc? in
            onRebuild?()
            if rebuildFails { return nil }
            var merged = relay.document
            for (key, value) in edit { merged[key] = value }
            return DerivedSyncDoc(document: merged, baseRevision: relay.revision, credentialCapture: capture,
                                  sourceIsCurrent: sourceIsCurrent, plaintextData: rebuiltPlaintext)
        }
#if BASELINE_SYNC_UPLOAD
        return await pushDerivedDoc(document, onAccepted: { [self] _ in acceptedCallbacks += 1 }) {
            await rebuild()?.document
        }
#else
        return await pushDerivedDoc(DerivedSyncDoc(document: document, baseRevision: base, credentialCapture: capture,
                                                 sourceIsCurrent: sourceIsCurrent, plaintextData: plaintext),
                                    onAccepted: { [self] _ in acceptedCallbacks += 1 }, rebuild: rebuild)
#endif
    }
}

@MainActor private enum RevisionChecks {
    static var failures = 0
    static func check(_ value: Bool, _ message: String) {
        if value { print("PASS \(message)") } else { failures += 1; print("FAIL \(message)") }
    }
    static func run() async {
        let relay = BackupRelay(revision: 100, document: ["existing": "retained"])
        let a = UploadHarness(relay), b = UploadHarness(relay)
        let base = relay.revision, original = relay.document
        var aDoc = original; aDoc["install"] = "A"
        var bDoc = original; bDoc["remove"] = "B"
        check(await a.send(aDoc, base: base, edit: ["install": "A"]), "first same-base peer stored")
        // Ensure the old epoch-based implementation obtains a later wall clock.
        try? await Task.sleep(nanoseconds: 5_000_000)
        check(await b.send(bDoc, base: base, edit: ["remove": "B"]), "second peer remerges after conflict")
        check(relay.document["install"] as? String == "A" && relay.document["remove"] as? String == "B",
              "same-base peer cannot erase the first peer's edit")
        check(a.sent == [101] && b.sent == [101, 102] && relay.revision == 102,
              "each attempt uses the base revision of that exact merged document")
        check(a.acceptedCallbacks == 1 && b.acceptedCallbacks == 1, "only stored documents acknowledge edits")
        check(a.witnesses == [100] && b.witnesses == [100, 101], "each PUT witnesses its candidate's own GET")

        let typedRelay = BackupRelay(revision: 11, document: ["peer": "retained"])
        let typed = UploadHarness(typedRelay)
        let firstPlaintext = Data(#"{"nativeCounter":18446744073709551615}"#.utf8)
        let retryPlaintext = Data(#"{"nativeCounter":18446744073709551615,"peer":"retained"}"#.utf8)
        check(await typed.send(["ackProjection": "first"], base: 10, edit: ["local": "edit"],
                               plaintext: firstPlaintext, rebuiltPlaintext: retryPlaintext),
              "typed plaintext candidate retries through the actual production method")
        check(typed.plaintexts == [firstPlaintext, retryPlaintext] && typed.witnesses == [10, 11],
              "each attempt forwards its own exact frozen plaintext, not the ACK projection or prior bytes")

        let moving = BackupRelay(revision: 51, document: ["peer": "retained"])
        let client = UploadHarness(moving); client.rejectedEcho = 9_999
        check(await client.send(["local": "edit"], base: 50, edit: ["local": "edit"]), "retry uses fresh pulled document")
        check(client.sent == [51, 52] && moving.document["peer"] as? String == "retained",
              "winner echo never supplies the revision of a different rebuilt base")

        let advancing = BackupRelay(revision: 51, document: ["peer": "retained"])
        let lateReader = UploadHarness(advancing); lateReader.rejectedEcho = 51
        lateReader.onRebuild = { advancing.revision = 900; advancing.document["laterPeer"] = "retained" }
        check(await lateReader.send(["local": "edit"], base: 50, edit: ["local": "edit"]),
              "a third peer may advance the relay before conflict recovery pulls")
        check(lateReader.sent == [51, 901] && advancing.document["laterPeer"] as? String == "retained",
              "retry binds to the newer pulled base rather than the lower rejection echo")

        let fresh = BackupRelay(revision: nil)
        let first = UploadHarness(fresh), second = UploadHarness(fresh)
        check(await first.send(["first": "seed"], base: nil, edit: ["first": "seed"]), "missing row inserts revision zero")
        check(await second.send(["second": "seed"], base: nil, edit: ["second": "seed"]), "competing seed pulls before retry")
        check(first.sent == [0] && second.sent == [0, 1] && fresh.document["first"] as? String == "seed",
              "a competing empty-base writer retains the winning seed")

        let refused = BackupRelay(revision: 15, document: ["winner": "kept"])
        let failed = UploadHarness(refused)
        check(!(await failed.send(["stale": "edit"], base: 14, edit: [:], rebuildFails: true)),
              "failed conflict pull refuses upload")
        check(failed.sent == [15] && failed.acceptedCallbacks == 0 && refused.document["winner"] as? String == "kept",
              "failed rebuild does not acknowledge or overwrite the winner")

        let retired = UploadHarness(refused)
        retired.onRebuild = { retired.retire() }
        check(!(await retired.send(["stale": "edit"], base: 14, edit: ["stale": "edit"])),
              "retired account cannot retry a rebuilt document")
        check(retired.sent == [15] && retired.acceptedCallbacks == 0, "retirement preserves pending intent")

        let lostRelay = BackupRelay(revision: 4, document: ["peer": "preserved"])
        let lost = UploadHarness(lostRelay); lost.loseAcceptedResponse = true
        check(!(await lost.send(["peer": "preserved", "local": "intent"], base: 4, edit: ["local": "intent"])),
              "lost accepted response remains unacknowledged")
        check(lost.acceptedCallbacks == 0 && lostRelay.revision == 5, "cloud commit is not a local receipt")
        lostRelay.document["concurrent"] = "retained"; lostRelay.revision = 6
        lost.loseAcceptedResponse = false
        check(await lost.send(["local": "intent"], base: 4, edit: ["local": "intent"]), "retry after lost response remerges")
        check(lostRelay.document["concurrent"] as? String == "retained" && lost.witnesses == [4, 4, 6],
              "ambiguous retry retains pending intent and intervening peer data")

        let missingHead = UploadHarness(BackupRelay(revision: nil))
        check(await missingHead.send(["local": "intent"], base: 8, edit: ["local": "intent"]), "existing candidate cannot pretend removed head is its base")
        check(missingHead.witnesses == [8, nil] && missingHead.sent == [9, 0], "missing-head retry requires a fresh absent read")
        let blocked = UploadHarness(BackupRelay(revision: 2)); blocked.upgradeRequired = true
        check(!(await blocked.send([:], base: 2, edit: [:])) && blocked.sent == [3] && blocked.acceptedCallbacks == 0,
              "update-needed never conflict-retries or acknowledges")
        let remounted = UploadHarness(BackupRelay(revision: 2))
        remounted.afterSending = { remounted.mountCurrent = false }
        check(!(await remounted.send([:], base: 2, edit: [:])) && remounted.acceptedCallbacks == 0,
              "mount replaced during upload cannot retire candidate intent")

        let exhausted = UploadHarness(BackupRelay(revision: SyncDocumentRevisionPolicy.maximumSafeRevision))
        check(!(await exhausted.send([:], base: SyncDocumentRevisionPolicy.maximumSafeRevision, edit: [:]))
              && exhausted.sent.isEmpty, "maximum JSON revision refuses overflow before transport")
        check(SyncDocumentRevisionPolicy.next(after: -1) == nil
              && SyncDocumentRevisionPolicy.next(after: Int.max) == nil
              && SyncDocumentRevisionPolicy.next(after: 0) == 1,
              "invalid stored revisions fail and a real zero row advances to one")
        if failures > 0 { exit(1) }
        print("PASS derived backup revision race and ownership checks")
    }
}

@main private enum SyncDerivedDocumentRevisionTests {
    static func main() async { await RevisionChecks.run() }
}
