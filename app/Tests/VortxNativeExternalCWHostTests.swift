import Foundation
import CryptoKit

/// Invoke from the existing watched-stream test entry with its retained app/build directory.
/// Actual encrypted store, worker, projector, Read and FIFO; synthetic data/transport only.
enum VortxNativeExternalCWHostTests {
    typealias T = VortxNativeWatchedArchiveTests
    struct Source: VortxMutationAuthority {
        func withActive(_ operation: () throws -> Void) throws { try operation() }
    }
    enum LostAcknowledgement: Error { case afterWrite }
    struct InspectingSource: VortxMutationAuthority {
        let store: VortxEncryptedCheckpointStore
        let failAfter: Bool
        func withActive(_ operation: () throws -> Void) throws {
            // Calls the actual store while source authority is held. The old store->source
            // order deadlocks here; the revised writer must not yet hold its file lock.
            _ = try store.captureMigrationDraft(scope: T.scope)
            try operation()
            if failAfter { throw LostAcknowledgement.afterWrite }
        }
    }
    struct Joined: VortxMutationAuthority {
        let original: VortxNativeFIFOAdmission.ReadCapability
        let draft: any VortxMutationAuthority
        let generation: VortxNativeExternalCW.Generation
        let expected: UUID
        func withActive(_ operation: () throws -> Void) throws {
            try original.withActive { try draft.withActive { try generation.withActive(expected, operation) } }
        }
    }
    static func candidate(_ id: String, key: String? = nil) -> VortxNativeExternalCW.Candidate {
        .init(key: key ?? id, type: "series", metaId: id, videoId: "opaque-unit-" + id,
              titleSpellings: [id], season: 1, episode: 2)
    }
    static func empty(_ marker: String) throws -> Data {
        try VortxNativeBootstrapArchive.encode(document: T.encode(["future": marker]))
    }
    static func rejected(_ label: String, _ operation: () throws -> Void) throws {
        var refused = false
        do { try operation() } catch { refused = true }
        T.check(refused, label)
    }
    static func run(directory: URL) async throws {
        let dir = directory.appendingPathComponent("external-cw-" + UUID().uuidString, isDirectory: true)
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let store = try VortxEncryptedCheckpointStore(directory: dir, key: key)
        let probe = try VortxEncryptedCheckpointStore(directory: dir, key: key)
        let a = try empty("A"), b = try empty("B")
        let absent = try store.captureMigrationDraft(scope: T.scope)
        T.check(absent.archive == nil, "genuine absence is captured, not inferred from an error")
        try absent.withActive {}
        try probe.retainMigrationDraft(a, scope: T.scope, expected: nil, authority: InspectingSource(store: probe, failAfter: false))
        try rejected("probe writer retires original absent receipt") { try absent.withActive {} }
        let firstA = try store.captureMigrationDraft(scope: T.scope)
        T.check(firstA.archive == a, "receipt retains exact authenticated A bytes")
        try rejected("wrong expected draft still rejects") {
            try probe.retainMigrationDraft(b, scope: T.scope, expected: nil, authority: Source())
        }
        try firstA.withActive {}
        try probe.retainMigrationDraft(b, scope: T.scope, expected: a, authority: Source())
        try probe.retainMigrationDraft(a, scope: T.scope, expected: b, authority: Source())
        T.check(try store.readMigrationDraft(scope: T.scope) == a, "A -> B -> A preserves current exact A")
        try rejected("A -> B -> A cannot revive old receipt") { try firstA.withActive {} }
        let beforeLostACK = try store.captureMigrationDraft(scope: T.scope)
        try rejected("post-write authority error remains an error") {
            try probe.retainMigrationDraft(b, scope: T.scope, expected: a, authority: InspectingSource(store: probe, failAfter: true))
        }
        T.check(try store.readMigrationDraft(scope: T.scope) == b, "lost acknowledgement fixture really wrote before throwing")
        try rejected("uncertain caller outcome retires previous receipt") { try beforeLostACK.withActive {} }
        let wrongKey = try VortxEncryptedCheckpointStore(directory: dir, key: SymmetricKey(data: Data(repeating: 8, count: 32)))
        try rejected("wrong key is not absence") { _ = try wrongKey.captureMigrationDraft(scope: T.scope) }

        // The exact real pending decoder identifies a title; another known title is not denied.
        let source = try T.source(bytes: 4096, count: 1)
        let pending = try await T.prepare(source, available: false)
        let journal = try VortxNativeWatchedArchive.retaining(a, pending: pending.pendingArchives, scope: T.scope)
        try probe.retainMigrationDraft(journal, scope: T.scope, expected: b, authority: Source())
        let candidates = [candidate("tt2934286"), candidate("unrelated")]
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: T.scope, isCurrent: { true })
        let prepared = try await worker.externalCWDenials(nil, store: store, profileID: T.owner.uuidString, candidates: candidates)
        T.check(prepared.denials.reason(for: "tt2934286") == "host_pending_watched"
            && prepared.denials.reason(for: "unrelated") == nil, "draft pending denial is title-specific")
        let completed = try await T.prepare(source)
        let resolved = try VortxNativeWatchedArchive.retaining(a, evidence: completed.archives, scope: T.scope)
        let joined = try await worker.externalCWDenials(resolved, store: store, profileID: T.owner.uuidString, candidates: candidates)
        T.check(joined.denials.reason(for: "tt2934286") == nil, "exact completed tuple in installed source resolves draft pending tuple")
        let duplicate = try await worker.externalCWDenials(journal, store: store, profileID: T.owner.uuidString, candidates: candidates)
        T.check(duplicate.denials.reason(for: "tt2934286") != nil, "duplicate unresolved source cannot clear itself")
        let gate = VortxNativeWatchedStreamTests.BoundaryGate(stop: 2)
        let parkedWorker = VortxNativeWatchedArchive.RecoveryWorker(scope: T.scope, isCurrent: { true },
            checkpoint: { try await gate.checkpoint() })
        let reading = Task {
            try await gate.run {
                try await parkedWorker.externalCWDenials(nil, store: store, profileID: T.owner.uuidString, candidates: candidates)
            }
        }
        try await gate.waitUntilParked() // After capture, before the cold replay completes.
        try probe.retainMigrationDraft(a, scope: T.scope, expected: journal, authority: Source())
        await gate.release()
        do { _ = try await reading.value; preconditionFailure("worker returned stale draft evidence") } catch {}
        try probe.retainMigrationDraft(journal, scope: T.scope, expected: a, authority: Source())

        // Worker reads real installed own-account pending and quarantine envelopes as denials.
        let child = UUID(uuidString: "91000000-0000-0000-0000-000000000019")!
        let overlay = try T.encode(["vortx": ["byProfile": [child.uuidString: ["library": [["id": "held", "type": "series"]]]]]])
        let pendingHost = try T.encode(["ownAccountOverlayPending": [child.uuidString:
            ["profileOverlayBase64": overlay.base64EncodedString(), "reason": "missing_witness"]]])
        let pendingEnvelope = try VortxNativeBootstrapArchive.replacingHostDocument(in: a, with: pendingHost)
        let overlayCandidates = [candidate("held"), candidate("unrelated")]
        let own = try await worker.externalCWDenials(pendingEnvelope, store: store, profileID: child.uuidString, candidates: overlayCandidates)
        T.check(own.denials.reason(for: "held") == "host_pending_overlay"
            && own.denials.reason(for: "unrelated") == nil, "own-account pending overlay denies only overlap")
        let quarantined = try VortxNativeUnattributedOverlayArchive.retaining(a, prior: nil, document: overlay,
            profileIDs: [child], scope: T.scope)
        let isolated = try await worker.externalCWDenials(quarantined, store: store, profileID: child.uuidString, candidates: overlayCandidates)
        T.check(isolated.denials.reason(for: "held") == "host_unattributed_overlay"
            && isolated.denials.reason(for: "unrelated") == nil, "unattributed overlay uses real profile/title attribution")
        let otherProfile = try await worker.externalCWDenials(quarantined, store: store,
            profileID: T.owner.uuidString, candidates: overlayCandidates)
        T.check(otherProfile.denials.reason(for: "held") == nil, "another profile's quarantine is not a global mask")

        try projectionCases(profileID: child.uuidString)
        // Offer lifetime uses the actual Read/FIFO plus the actual draft receipt, not a
        // duplicated state machine. There is no fake native ABI/eligible production adapter.
        let fifo = VortxNativeFIFOAdmission(lock: NSRecursiveLock())
        let original = try fifo.capture(source: Source()) {}
        let draft = try store.captureMigrationDraft(scope: T.scope)
        let generation = VortxNativeExternalCW.Generation(), metadataReceipt = UUID()
        let held = generation.capture()
        let read = VortxNativeExternalCW.Read(original: original, metadataCurrent: { _ in true }, prepare: { id in
            .init(id: id, type: "series", videos: [.init(id: "opaque-unit-" + id, season: 1, episode: 2)], receipt: metadataReceipt)
        }, resolve: { input in
            .init(verdicts: input.map { .init(key: $0.key, disposition: .eligible, reason: "clear") },
                authority: Joined(original: original, draft: draft.authority, generation: generation, expected: held))
        })
        _ = try await read.prepareMetadata(id: "unrelated")
        _ = try await read.query([candidate("unrelated")])
        T.check(read.isCurrent(), "successful read remains reading, not finished")
        do { _ = try await read.query([candidate("unrelated")]); preconditionFailure("re-query recaptured authority") } catch {}
        try probe.retainMigrationDraft(a, scope: T.scope, expected: journal, authority: Source())
        T.check(!read.isCurrent(), "later probe draft write retires an already offered card")
        try probe.retainMigrationDraft(journal, scope: T.scope, expected: a, authority: Source())
        T.check(!read.isCurrent(), "restoring the same draft cannot revive that offer")
        let stamp = generation.capture(); generation.retire()
        try rejected("Session generation change invalidates a prepared epoch") { try generation.withActive(stamp) {} }
        print("External CW host sources: actual draft receipts, pending/quarantine projection and offer lifetime passed")
    }

    static func projectionCases(profileID: String) throws {
        let nfc = "\u{00e9}", nfd = "e\u{0301}"
        let values = [candidate(nfc, key: "nfc"), candidate(nfd, key: "nfd"), candidate("other")]
        var denials = try VortxNativeExternalCWPending.Denials(candidates: values)
        let raw = Data(("{\"vortx\":{\"byProfile\":{\"" + profileID + "\":{\"library\":[{\"id\":\"" + nfc
            + "\",\"type\":\"series\",\"future\":-0}]}}}}").utf8)
        let before = raw
        try denials.overlay(raw, profileID: profileID, reason: "held", check: {})
        T.check(denials.reason(for: "nfc") != nil && denials.reason(for: "nfd") == nil
            && denials.reason(for: "other") == nil && raw == before, "opaque bytes, unrelated candidate and raw negative zero survive")
        let native: [VortxNativeExternalCW.Verdict] = [.init(key: "nfc", disposition: .suppressed, reason: "native_tombstone"),
            .init(key: "nfd", disposition: .unresolved, reason: "native_unknown"), .init(key: "other", disposition: .eligible, reason: "clear")]
        T.check(try denials.narrowing(native) == native, "host denial never overwrites native suppressed/unresolved disposition")
        var removals = try VortxNativeExternalCWPending.Denials(candidates: [candidate("offered")])
        let knownOther = try T.encode(["vortx": ["byProfile": [profileID: [
            "library": [["id": "known-other", "type": "series"]],
            "removed": [["keys": ["series\u{1f}known-other"], "removedAt": 1]]]]]])
        try removals.overlay(knownOther, profileID: profileID, reason: "held", check: {})
        T.check(removals.reason(for: "offered") == nil, "known unrelated removal is not a whole-profile denial")
        let unknown = try T.encode(["webProgress": ["removed": ["byProfile": [profileID:
            [["keys": ["unattributed-alias"], "removedAt": 1]]]]]])
        try removals.overlay(unknown, profileID: profileID, reason: "unattributed", check: {})
        T.check(removals.reason(for: "offered") != nil, "truly unattributable removal fails closed")
    }
}
