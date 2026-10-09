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
    private enum PushOutcome { case accepted(version: Int); case rejected(storedVersion: Int?); case error }
    private let credentialAuthority = FixtureAuthority()
    let relay: BackupRelay
    var sent: [Int] = []
    var acceptedCallbacks = 0
    var pendingApply = false
    var networkFailure = false
    var rejectedEcho: Int?
    var onRebuild: (() -> Void)?

    init(_ relay: BackupRelay) { self.relay = relay }
    private func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool {
        capture == credentialAuthority.capture()
    }
    private func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pendingApply }
    private func pushSyncDocAt(_ document: [String: Any], version: Int,
                               credentialCapture capture: CredentialScopeRegistry.Capture) async -> PushOutcome {
        guard isCurrent(capture), !pendingApply else { return .error }
        sent.append(version)
        if networkFailure { return .error }
        if let stored = relay.revision, version <= stored { return .rejected(storedVersion: rejectedEcho ?? stored) }
        relay.revision = version; relay.document = document
        return .accepted(version: version)
    }
    func retire() { credentialAuthority.generation += 1 }

    func send(_ document: [String: Any], base: Int?, edit: [String: String],
              rebuildFails: Bool = false) async -> Bool {
        let rebuild = { [self] () async -> DerivedSyncDoc? in
            onRebuild?()
            if rebuildFails { return nil }
            var merged = relay.document
            for (key, value) in edit { merged[key] = value }
            return DerivedSyncDoc(document: merged, baseRevision: relay.revision)
        }
#if BASELINE_SYNC_UPLOAD
        return await pushDerivedDoc(document, onAccepted: { [self] _ in acceptedCallbacks += 1 }) {
            await rebuild()?.document
        }
#else
        return await pushDerivedDoc(DerivedSyncDoc(document: document, baseRevision: base),
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
