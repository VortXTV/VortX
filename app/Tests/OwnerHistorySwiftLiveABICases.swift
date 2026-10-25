import Foundation
import CryptoKit

/// Actual CABI delegator, not a substitute ABI. Every successful callback must FIRST pass
/// the Coordinator's production full/raw/fence verifier. The only injected result is denial.
private final class OwnerHistoryLiveABIProbe: OwnerHistorySessionABI, @unchecked Sendable {
    struct Counts {
        var opens = 0, forks = 0, frees = 0, denied = 0
        var requests: [String: Int] = [:]
        var verified: [String: Int] = [:]
        var live: Set<UInt> = []
        var keyedEmpty = 0, keyedMutations = 0, keyedMultiPublication = 0, keyedOracleMatches = 0, keyedAccepts = 0
    }
    private let real = OwnerHistorySessionCABI()
    private let lock = NSLock()
    private var state = Counts()
    private var denyNext: String?
    private var snapshots: [UInt: Data] = [:]
    private var forkBases: [UInt: OwnerHistoryExactJSON.Snapshot] = [:]
    private var keyedAwaitingAccept: Set<UInt> = []
    func counts() -> Counts { lock.withLock { state } }
    func denyNextFullCallback(during operation: String) { lock.withLock { denyNext = operation } }
    private func checked(_ verify: @escaping Verify, operation: String) -> Verify {
        { [self] bytes in
            try verify(bytes) // Real raw journal/canonicalizer, exact scope/binding/fence proof.
            let kind = try OwnerHistoryExactJSON.Object(bytes).text("kind")
            let denied = lock.withLock {
                state.verified[kind, default: 0] += 1
                guard denyNext == operation, kind == "full" else { return false }
                denyNext = nil; state.denied += 1; return true
            }
            if denied { throw VortxNativeError.superseded }
        }
    }
    func open(_ snapshot: String, verify: @escaping Verify) -> UInt {
        lock.withLock { state.opens += 1 }
        let handle = real.open(snapshot, verify: checked(verify, operation: "open"))
        if handle != 0 { lock.withLock { _ = state.live.insert(handle); snapshots[handle] = Data(snapshot.utf8) } }
        return handle
    }
    func fork(_ session: UInt, fence: String, verify: @escaping Verify) -> UInt {
        lock.withLock { state.forks += 1 }
        let handle = real.fork(session, fence: fence, verify: checked(verify, operation: "fork"))
        if handle != 0 {
            lock.withLock {
                _ = state.live.insert(handle)
                guard let snapshot = snapshots[session],
                      let parent = try? OwnerHistoryExactJSON.Object(Data(fence.utf8)),
                      let witness = try? parent.text("sourceSetWitnessId"),
                      let base = try? OwnerHistoryExactJSON.Snapshot(bytes: snapshot, witnessID: witness, fence: Data(fence.utf8))
                else { preconditionFailure("actual live ABI fork baseline missing") }
                snapshots[handle] = snapshot; forkBases[handle] = base
            }
        }
        return handle
    }
    func request(_ session: UInt, json: String, now: UInt64, verify: @escaping Verify) -> String? {
        let kind = (try? OwnerHistoryExactJSON.Object(Data(json.utf8)).text("kind")) ?? "malformed"
        lock.withLock { state.requests[kind, default: 0] += 1 }
        let response = real.request(session, json: json, now: now,
            verify: checked(verify, operation: "request:" + kind))
        // Genuine native output, actual consumer, and an independent COMPLETE native
        // checkpoint oracle from the same candidate. No result/success/fence is fabricated.
        if let response {
            do {
                typealias Exact = OwnerHistoryExactJSON
                let reply = try Exact.Object(Data(response.utf8))
                let responseKind = try reply.text("kind")
                if kind == "checkpoint_delta", responseKind == "checkpoint_delta", reply["deltaEncoding"] == nil {
                    guard let base = lock.withLock({ forkBases[session] }) else { preconditionFailure("coarse actual base missing") }
                    let request = try Exact.Object(Data(json.utf8))
                    let applied = try base.applying(checkpoint: Data(response.utf8), expectedFence: request.required("fence"))
                    lock.withLock { _ = keyedAwaitingAccept.remove(session); snapshots[session] = applied.bytes }
                }
                if kind == "accept", responseKind == "accepted" {
                    lock.withLock { if keyedAwaitingAccept.remove(session) != nil { state.keyedAccepts += 1 } }
                }
                if try reply.text("kind") == "checkpoint", let base = lock.withLock({ forkBases[session] }) {
                    let fence = try reply.required("fence")
                    let complete = try base.replacingNativeState(reply.required("state"),
                        witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
                    lock.withLock { snapshots[session] = complete.bytes }
                }
                if reply["deltaEncoding"] != nil {
                    guard let base = lock.withLock({ forkBases[session] }) else { preconditionFailure("keyed actual base missing") }
                    let request = try Exact.Object(Data(json.utf8)), expected = try request.required("fence")
                    let applied = try base.applying(checkpoint: Data(response.utf8), allowKeyed: true, expectedFence: expected)
                    let steps = try Exact.array(reply.required("keyedStateSteps"))
                    lock.withLock {
                        if steps.isEmpty { state.keyedEmpty += 1 } else { state.keyedMutations += 1 }
                        if steps.count >= 2 { state.keyedMultiPublication += 1 }
                        if steps.isEmpty { _ = keyedAwaitingAccept.remove(session) } else { _ = keyedAwaitingAccept.insert(session) }
                    }
                    let fullRequest = #"{"kind":"checkpoint","fence":\#(String(decoding: expected, as: UTF8.self))}"#
                    guard let full = real.request(session, json: fullRequest, now: now,
                        verify: checked(verify, operation: "request:keyed_full_oracle")) else { preconditionFailure("actual full oracle missing") }
                    let oracle = try Exact.Object(Data(full.utf8))
                    guard try oracle.text("kind") == "checkpoint",
                          try Exact.canonical(oracle.required("fence")) == Exact.canonical(expected) else { preconditionFailure("actual full oracle rejected") }
                    let expectedState = try base.replacingNativeState(oracle.required("state"),
                        witnessID: Exact.Object(expected).text("sourceSetWitnessId"), fence: expected)
                    let matches = try Exact.canonical(applied.bytes) == Exact.canonical(expectedState.bytes)
                    precondition(matches)
                    lock.withLock { snapshots[session] = applied.bytes; state.keyedOracleMatches += 1 }
                }
            } catch { preconditionFailure("actual keyed ABI oracle failure: \(error)") }
        }
        return response
    }
    func free(_ session: UInt) {
        real.free(session)
        lock.withLock { state.frees += 1; _ = state.live.remove(session); snapshots.removeValue(forKey: session); forkBases.removeValue(forKey: session); keyedAwaitingAccept.remove(session) }
    }
}

/// Only the secure-backend boundary is synthetic. The actual production witness compares its
/// exact originally confirmed bytes under the real provider-store lock; no Keychain is read.
private final class OwnerHistoryLiveProviderBytes: @unchecked Sendable {
    private let lock = NSLock()
    private let slot: String
    private var bytes: String
    init(slot: String, bytes: String) { self.slot = slot; self.bytes = bytes }
    func read(_ slot: String) -> CredentialDurableReadResult {
        lock.withLock { slot == self.slot ? .value(bytes) : .failure }
    }
    func replace(_ value: String) { lock.withLock { bytes = value } }
}

/// Invoked by the EXISTING live-ABI main. These are authored integration assertions, UNRUN.
/// Real native create/bind, stateless evidence canonicalization, owner-session open/fork/request/
/// free, production verifier/raw replay, actual FIFO and encrypted Store are not replaced.
enum OwnerHistorySwiftLiveABICases {
    private typealias Exact = OwnerHistoryExactJSON
    private typealias Coordinator = OwnerHistorySessionCoordinator
    private static func check(_ condition: Bool, line: Int = #line) {
        precondition(condition, "owner-history live ABI assertion at line \(line)")
    }
    private static func rejects(_ operation: () throws -> Void, line: Int = #line) {
        var rejected = false
        do { try operation() } catch { rejected = true }
        check(rejected, line: line)
    }

    static func run(checkpointDirectory: URL) throws {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let actor = "00000000-0000-0000-0000-000000000072"
        let uid = "synthetic-swift-live-owner"
        let scope = VortxAccountScope(account: "synthetic.swift-live-owner-history", ownerProfileID: owner.uuidString)
        let target = Coordinator.Target(profileID: owner, verifiedUID: uid)
        let lifetime = XperienceImportLifetime() // Explicitly revocable synthetic account/source boundary.
        let fifo = VortxNativeFIFOAdmission(lock: NSRecursiveLock())
        defer { fifo.close() }
        let abi = OwnerHistoryLiveABIProbe()
        let canonicalizer = OwnerHistoryExactSourceValidation(abi: VortxCABI())
        let key = SymmetricKey(size: .bits256)
        let directory = checkpointDirectory.appendingPathComponent("owner-history-swift-live")
        let host = try VortxNativeHostPreferences(scope: scope, actor: actor).encoded()

        // No host-written native state or schema promotion: this complete snapshot comes from
        // the real ordinary engine, which is retired before any owner-session runtime opens.
        let seed = try VortxNativeRuntime(abi: VortxCABI(), ownerID: owner.uuidString, ownerName: "Fixture")
        let initial: Data
        do {
            check(try seed.dispatch(#"{"type":"bind_sync_scope","scope":"\#(scope.account)"}"#,
                now: 1).contains(#""ok":true"#))
            initial = try Data(seed.stateJSON().utf8)
            seed.close()
        } catch { seed.close(); throw error }
        let initialNative = try Exact.Object(initial).required("nativeSync")
        // NativeSyncDocument.seed emits schema 1 for a pristine owner. Higher schemas
        // require their actual account/website/history material, not a host-authored bump.
        check(try Exact.Object(initialNative).required("schemaVersion") == Data("1".utf8))
        check(try Exact.Object(initialNative)["ownerHistory"] == nil)
        let source = try VortxNativeOwnerHistorySource.Capture(scope: scope, profileID: owner,
            verifiedUID: uid, snapshotData: initial)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        try store.commit(String(decoding: initial, as: UTF8.self), scope: scope, hostPreferences: host)
        guard let original = try store.readOwnerHistory(scope: scope) else {
            preconditionFailure("original encrypted live fixture missing")
        }

        // Immutable synthetic upstream bytes are the ONLY authored source. Production replay
        // derives every typed library/watch row; Rust derives sourceId, receipt and attestation.
        let library = Data(#"{"result":[{"_id":"historical","type":"movie","name":"Historical","future":{"original":1e3,"negativeZero":-0.0,"wide":9007199254740993},"state":{"timeOffset":1234,"duration":5000,"lastWatched":"2026-01-01T00:00:00.125Z","flaggedWatched":0}}],"unknown":{"retain":true}}"#.utf8)
        let addons = Data(#"{"result":{"addons":[]}}"#.utf8)
        let frame = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "kind": "vortx.owner-history.source/1", "scope": scope.account,
            "ownerProfileId": owner.uuidString, "profileId": owner.uuidString, "verifiedStreamingUid": uid,
            "libraryResponseBase64": library.base64EncodedString(),
            "addonsResponseBase64": addons.base64EncodedString()
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let archive = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "kind": "vortx.owner-history.archive/1",
            "sourceDocumentBase64": frame.base64EncodedString(), "metadataEvidenceBase64": [String]()
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let replayed = try VortxNativeOwnerHistoryPreparation.replay(archive: archive, scope: scope.account,
            ownerProfileID: owner, profileID: owner, verifiedUID: uid, authority: lifetime)
        check(replayed.archive == archive && replayed.frame.sourceDocument == frame)
        let canonical = try canonicalizer.canonicalize(replayed.evidence)
        let sourceID = try Exact.Object(canonical.receipt).text("sourceId")
        check(!sourceID.isEmpty)
        check(try canonicalizer.canonicalize(replayed.evidence).receipt == canonical.receipt)
        rejects { _ = try canonicalizer.canonicalize(Data("{}".utf8)) }

        // Real complete-account/provider policy and full encoded budget, with a synthetic
        // confirmed secure slot. No constant checkpoint validator/empty whole-account budget.
        let provider = try VortxNativeProviderCredentials(scope: scope.account, actor: actor)
        let providerText = String(decoding: try provider.encoded(), as: UTF8.self)
        let providerBytes = OwnerHistoryLiveProviderBytes(slot: "synthetic-provider-slot", bytes: providerText)
        let observation = XperienceExportObservationFence()
        let observed = observation.observe()
        let witness = XperienceExportWitnessAuthority(observation: observation, generation: observed,
            providerSlot: "synthetic-provider-slot", providerBytes: providerText,
            providerRead: { [providerBytes] in providerBytes.read($0) })
        let hostProjection = try OwnerHistoryAccountExport.hostProjection(host, scope: scope)
        let unknown = Data(#"{"wide":9007199254740993,"negativeZero":-0.0,"overflow":1e999,"tombstone":null}"#.utf8)
        var full = try Exact.Object(Data("{}".utf8))
        full.set("nativeSync", initialNative)
        full.set("nativeHostPreferences", hostProjection.document)
        full.set("profileEditResults", hostProjection.profileEditResults)
        full.set("unknownAccount", unknown)
        let account = try OwnerHistoryRawAccountPreparation.reconcile(plaintext: full.encoded(),
            source: source, snapshotData: initial, hostPreferencesData: host,
            ownerHistoryLocalData: nil, readOwnerUID: uid, provider: provider)
        let transaction = OwnerHistoryPreparedExport(completeAccount: account, scope: scope,
            writeV2: true, authority: witness)

        let coordinator = try Coordinator(scope: scope, target: target, store: store,
            abi: abi, canonicalABI: VortxCABI(), sourceAuthority: lifetime,
            originalRead: original, initialOwnerReadUID: uid)
        defer { check(coordinator.close()) }
        func capture(_ owner: Coordinator) throws -> (VortxNativeFIFOAdmission.ReadCapability, Coordinator.Capture) {
            let read = try fifo.capture(source: lifetime, validate: { try Task.checkCancellation() })
            let captured = try owner.capture(target: target, sourceAuthority: lifetime,
                queueAuthority: read.queueAuthority)
            return (read, captured)
        }
        func running<T>(_ read: VortxNativeFIFOAdmission.ReadCapability,
                        _ operation: () throws -> T) throws -> T {
            rejects { try read.runningAuthority.withActive {} } // Reading is NOT running.
            var installed: VortxNativeFIFOAdmission.Member?
            try fifo.admit(read) { installed = $0 }
            guard let member = installed else { throw VortxNativeError.superseded }
            try member.begin()
            defer { member.finish() }
            return try operation()
        }
        func importSource(deny: Bool) throws -> Coordinator.DurableImport {
            let (read, captured) = try capture(coordinator)
            // Each intentional attempt replays under its own ORIGINAL read; a failed gesture
            // is never revived with a freshly captured queue lease or an old prepared wrapper.
            let prepared = try VortxNativeOwnerHistoryPreparation.replay(archive: archive, scope: scope.account,
                ownerProfileID: owner, profileID: owner, verifiedUID: uid, authority: captured)
            let bound = try coordinator.bind(.prepared(prepared), source: source, capture: captured)
            if deny { abi.denyNextFullCallback(during: "request:import") }
            return try running(read) { try coordinator.importPrepared(bound, transaction: transaction) }
        }

        // Reject only AFTER real production verification; the real C callback returns denial.
        // The staged native child is freed and neither original ciphertext nor parent changes.
        rejects { _ = try importSource(deny: true) }
        check(abi.counts().denied == 1 && abi.counts().live.count == 1)
        try store.requireCurrentOwnerHistory(original, scope: scope)
        check(try Exact.canonical(coordinator.acknowledgedSnapshot()) == Exact.canonical(initial))

        let accepted = try importSource(deny: false)
        check(try Exact.Object(accepted.receipt).text("sourceId") == sourceID)
        check(try Exact.canonical(accepted.receipt) == Exact.canonical(canonical.receipt))
        check(try Exact.Object(accepted.checkpoint.nativeSync).required("schemaVersion") == Data("6".utf8))
        check(try Exact.Object(accepted.checkpoint.nativeSync)["ownerHistory"] != nil)
        check(accepted.checkpoint.hostPreferences == host)
        rejects { try store.requireCurrentOwnerHistory(original, scope: scope) }
        guard let installed = try store.readOwnerHistory(scope: scope),
              let local = installed.ownerHistoryLocal, let base = installed.ownerHistoryAccountBase else {
            preconditionFailure("genuine source commit did not retain complete encrypted account")
        }
        check(installed.format == "vortx-native-owner-history-checkpoint-v1")
        check(installed.snapshot == accepted.checkpoint.snapshot && installed.preservedOwnerUID == uid)
        check(try OwnerHistoryAccountExport(completeAccountPlaintext: base).raw("unknownAccount") == unknown)
        let localObject = try Exact.Object(local)
        let journalBytes = Data(base64Encoded: try localObject.text("journalBase64"))!
        let journal = try VortxNativeOwnerHistoryJournal(bytes: journalBytes, scope: scope.account, ownerProfileID: owner)
        check(journal.entries.count == 1 && journal.entries[sourceID]?.archive == archive)
        try canonicalizer.validate(snapshot: installed.snapshot, journal: journal, scope: scope, authority: lifetime)
        let replay = try journal.replayAll(expectedSourceIDs: [sourceID], authority: lifetime)
        check(try canonicalizer.canonicalize(replay.evidenceBySourceID[sourceID]!).receipt == canonical.receipt)
        let carrier = try OwnerHistoryAccountExport(completeAccountPlaintext: base).raw(OwnerHistoryAccountExport.archiveKey)!
        check(try Exact.canonical(OwnerHistoryAccountExport.localArchive(from: carrier, scope: scope)) == Exact.canonical(local))
        check(try OwnerHistoryAccountExport.readOwnerUID(from: carrier, scope: scope) == uid)
        _ = try OwnerHistoryAccountExport(completeAccountPlaintext: base).cloudPlaintext(writeV2: true)
        rejects { _ = try store.read(scope: scope) } // No generic sidecar-stripping downgrade.
        check(coordinator.close() && abi.counts().live.isEmpty)

        // NEW Store decrypts the same real AES envelope; cold open performs production full
        // journal/source replay and native normalization verification again, not cached state.
        let coldStore = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        guard let coldOriginal = try coldStore.readOwnerHistory(scope: scope) else {
            preconditionFailure("cold typed checkpoint missing")
        }
        check(coldOriginal.ownerHistoryLocal == local && coldOriginal.ownerHistoryAccountBase == base)
        let cold = try Coordinator(scope: scope, target: target, store: coldStore,
            abi: abi, canonicalABI: VortxCABI(), sourceAuthority: lifetime, originalRead: coldOriginal)
        defer { check(cold.close()) }
        func playback(_ captured: Coordinator.Capture) throws -> VortxJSON {
            let request = Data(#"{"kind":"profile_playback","profileId":"\#(owner.uuidString)"}"#.utf8)
            let response = try Exact.Object(cold.read(kind: "resolve", capture: captured, extra: ["request": request]))
            check(try response.text("kind") == "resolved")
            return try JSONDecoder().decode(VortxJSON.self, from: response.required("result"))
        }
        let (_, beforeRead) = try capture(cold)
        check(try playback(beforeRead)["watchedTitles"]?["historical"] == nil)
        let ordinaryTransaction = OwnerHistoryPreparedExport(
            completeAccount: try OwnerHistoryAccountExport(completeAccountPlaintext: base),
            scope: scope, writeV2: true, authority: witness)
        let (actionRead, actionCapture) = try capture(cold)
        let action = Data(#"{"type":"mark_watched","metaId":"historical"}"#.utf8)
        _ = try running(actionRead) {
            // A NEW ordinary user action has an explicit deterministic fixture time. Historical
            // source rows above were never replayed as current-clock watched/progress actions.
            try cold.dispatch([action], nowUnixSeconds: 2_000_000_000,
                capture: actionCapture, transaction: ordinaryTransaction)
        }
        rejects { try actionCapture.withReadAuthority {} } // Settled original member is retired.
        rejects { try beforeRead.withReadAuthority {} } // Ordinary admission retired old reads.
        let (_, afterRead) = try capture(cold)
        check(try playback(afterRead)["watchedTitles"]?["historical"] != nil)
        guard let after = try coldStore.readOwnerHistory(scope: scope),
              let afterBase = after.ownerHistoryAccountBase else { preconditionFailure("ordinary typed ACK missing") }
        check(after.ownerHistoryLocal == local && after.hostPreferences == host)
        let exported = try OwnerHistoryAccountExport(completeAccountPlaintext: afterBase)
        check(exported.raw("unknownAccount") == unknown && exported.raw(OwnerHistoryAccountExport.archiveKey) == carrier)
        try canonicalizer.validate(snapshot: after.snapshot, journal: journal, scope: scope, authority: lifetime)
        _ = try exported.cloudPlaintext(writeV2: true)

        // The first mark creates native watch topology and is legitimately coarse. A second
        // real ordinary mutation now uses an existing watch bucket. Require a NONEMPTY keyed
        // checkpoint to cross complete-account validation, encrypted readback and native Accept.
        let beforeKeyedAccept = abi.counts()
        let keyedTransaction = OwnerHistoryPreparedExport(
            completeAccount: try OwnerHistoryAccountExport(completeAccountPlaintext: afterBase),
            scope: scope, writeV2: true, authority: witness)
        let (keyedRead, keyedCapture) = try capture(cold)
        _ = try running(keyedRead) {
            try cold.dispatch([Data(#"{"type":"reset_watched","metaId":"historical"}"#.utf8)],
                nowUnixSeconds: 2_000_000_001, capture: keyedCapture, transaction: keyedTransaction)
        }
        rejects { try keyedCapture.withReadAuthority {} }
        let (_, keyedPlayback) = try capture(cold)
        check(try playback(keyedPlayback)["watchedTitles"]?["historical"] == nil)
        guard let keyedAfter = try coldStore.readOwnerHistory(scope: scope),
              let keyedBase = keyedAfter.ownerHistoryAccountBase else { preconditionFailure("keyed durable ACK missing") }
        rejects { try coldStore.requireCurrentOwnerHistory(after, scope: scope) }
        check(keyedAfter.ownerHistoryLocal == local && keyedAfter.hostPreferences == host)
        let keyedExport = try OwnerHistoryAccountExport(completeAccountPlaintext: keyedBase)
        check(keyedExport.raw("unknownAccount") == unknown && keyedExport.raw(OwnerHistoryAccountExport.archiveKey) == carrier)
        try canonicalizer.validate(snapshot: keyedAfter.snapshot, journal: journal, scope: scope, authority: lifetime)
        _ = try keyedExport.cloudPlaintext(writeV2: true)
        let afterKeyedAccept = abi.counts()
        check(afterKeyedAccept.keyedMutations > beforeKeyedAccept.keyedMutations)
        check(afterKeyedAccept.keyedAccepts == beforeKeyedAccept.keyedAccepts + 1)
        let currentTransaction = OwnerHistoryPreparedExport(completeAccount: keyedExport,
            scope: scope, writeV2: true, authority: witness)
        // Two real dispatch publications on ONE original fork. Candidate dispatch applies
        // the cumulative journal to its retained base; the probe compares BOTH checkpoints
        // against real full native output. Dropping this candidate must not write the store.
        let (multiRead, multiCapture) = try capture(cold)
        try running(multiRead) {
            let candidate = try cold.candidate(capture: multiCapture, transaction: currentTransaction)
            defer { check(candidate.close()) }
            let accepted = try cold.acknowledgedSnapshot()
            check(try candidate.dispatch(#"{"type":"reset_watched","metaId":"historical"}"#,
                now: 2_000_000_003).contains(#""ok":true"#))
            check(try candidate.dispatch(#"{"type":"mark_watched","metaId":"historical"}"#,
                now: 2_000_000_004).contains(#""ok":true"#))
            check(try cold.acknowledgedSnapshot() == accepted)
        }
        try coldStore.requireCurrentOwnerHistory(keyedAfter, scope: scope)

        // Real witness rejects changed confirmed provider bytes AND an intervening observed
        // envelope. These are not constant-success authorities; neither failure may write disk.
        providerBytes.replace(providerText + " ")
        let (driftRead, driftCapture) = try capture(cold)
        rejects {
            _ = try running(driftRead) {
                try cold.dispatch([action], nowUnixSeconds: 2_000_000_001,
                    capture: driftCapture, transaction: ordinaryTransaction)
            }
        }
        try coldStore.requireCurrentOwnerHistory(keyedAfter, scope: scope)
        providerBytes.replace(providerText)
        observation.observe()
        let (observedRead, observedCapture) = try capture(cold)
        rejects {
            _ = try running(observedRead) {
                try cold.dispatch([action], nowUnixSeconds: 2_000_000_002,
                    capture: observedCapture, transaction: ordinaryTransaction)
            }
        }
        try coldStore.requireCurrentOwnerHistory(keyedAfter, scope: scope)
        let (_, revokedCapture) = try capture(cold)
        lifetime.revoke()
        rejects { _ = try cold.read(kind: "view", capture: revokedCapture) }
        try coldStore.requireCurrentOwnerHistory(keyedAfter, scope: scope)
        check(cold.close())
        let calls = abi.counts()
        check(calls.opens == 2 && calls.forks >= 3 && calls.live.isEmpty && calls.frees >= 4)
        check(calls.requests["import", default: 0] == 2 && calls.requests["checkpoint", default: 0] >= 1)
        check(calls.requests["accept", default: 0] >= 2 && calls.requests["dispatch", default: 0] >= 1)
        check(calls.verified["full", default: 0] >= 6 && calls.verified["lease", default: 0] > 0)
        check(calls.keyedEmpty >= 1 && calls.keyedMutations >= 1 && calls.keyedMultiPublication >= 1)
        check(calls.keyedOracleMatches == calls.keyedEmpty + calls.keyedMutations)
        check(calls.keyedAccepts >= 1)
        print("Live Swift owner history: real canonicalizer/open/fork/request/free, production full verifier, callback denial without ACK, genuine source import, FIFO + AES CAS, cold replay, ordinary mutation and exact raw export passed")
    }
}
