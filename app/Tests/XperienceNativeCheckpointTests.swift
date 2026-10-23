import Foundation
import CryptoKit

/// Exercises actual native Session+Facade, the supplied ABI and encrypted checkpoint store.
/// Takes a caller-provided disposable directory. Never opens an account, app, device or network.
private final class XperienceCountingCheckpointStore: VortxCheckpointStore, @unchecked Sendable {
    let backing: VortxEncryptedCheckpointStore
    private let lock = NSLock()
    private var writes = 0
    private var failAfterNextDurableCommit = false
    private var postWriteFailures = 0
    enum InjectedFailure: Error { case afterDurableCommit }
    init(_ backing: VortxEncryptedCheckpointStore) { self.backing = backing }
    var count: Int { lock.withLock { writes } }
    var injectedFailureCount: Int { lock.withLock { postWriteFailures } }
    func armPostWriteFailure() { lock.withLock { failAfterNextDurableCommit = true } }
    private func didDurablyCommit() throws {
        let fail = lock.withLock { () -> Bool in
            writes += 1
            guard failAfterNextDurableCommit else { return false }
            failAfterNextDurableCommit = false; postWriteFailures += 1; return true
        }
        // The REAL encrypted backing has completed its write/readback before this injected error.
        if fail { throw InjectedFailure.afterDurableCommit }
    }
    func read(scope: VortxAccountScope) throws -> String? { try backing.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try backing.readHostPreferences(scope: scope) }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { try backing.readLegacyMaterial(scope: scope) }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { try backing.readLegacyProfileEdits(scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        try backing.commit(snapshot, scope: scope); try didDurablyCommit()
    }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try backing.commit(snapshot, scope: scope, hostPreferences: hostPreferences); try didDurablyCommit()
    }
}
private final class XperiencePublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var publications = 0
    var count: Int { lock.withLock { publications } }
    func record() { lock.withLock { publications += 1 } }
}
private final class XperienceTestGateAuthority: VortxMutationAuthority, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lifetime: XperienceImportLifetime?
    init(lifetime: XperienceImportLifetime? = nil) { self.lifetime = lifetime }
    func withActive(_ operation: () throws -> Void) throws {
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw VortxNativeError.superseded }
        if let lifetime { try lifetime.withActive(operation) } else { try operation() }
    }
}
private struct XperienceTestOwnerAuthority: VortxMutationAuthority {
    func withActive(_ operation: () throws -> Void) throws { try operation() }
}
@main @MainActor enum XperienceNativeCheckpointTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func register(_ facade: VortxNativeCoreFacade, profile: String, field: String) throws -> VortxJSON? {
        guard let data = facade.stateData("native_host_preferences") else { throw Failure.assertion("host unavailable") }
        return try JSONDecoder().decode(VortxJSON.self, from: data)["profiles"]?[profile]?["fields"]?[field]
    }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func document(_ padding: Int = 0) throws -> XperienceCollections.Document {
        try XperienceCollections.project(.array([.object(["id": .string("collection"), "title": .string("Synthetic"),
            "future": .string(String(repeating: "x", count: padding)),
            "folders": .array([.object(["id": .string("folder"), "title": .string("Folder"), "sources": .array([])])])])]))
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("disposable directory required") }
        let owner = "10000000-0000-0000-0000-000000000071"
        let scope = VortxAccountScope(account: "synthetic.xperience-checkpoint", ownerProfileID: owner)
        let backing = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]),
            key: SymmetricKey(size: .bits256))
        let store = XperienceCountingCheckpointStore(backing)
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic", abi: VortxCABI(),
            store: store, transport: VortxCResourceTransport(), allowNewAccount: true)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: session.resourceRegistry(), changed: { _ in })
        guard let binding = facade.watchlistBinding, let registry = facade.registryBinding else { throw Failure.assertion("native context unavailable") }
        let initialState = try store.read(scope: scope), initialHost = try store.readHostPreferences(scope: scope)
        let edit = try XperienceImportNamespace.append(document: document(), label: "Initial", bindings: [:])
        let rejected = try XperienceExportBudget(completeAccountDocument: .object(["preserved": .string("old")]),
            maximumSealedBytes: 1, writeV2: true)
        let before = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(edit.nativeEdit, expected: binding, registry: registry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: rejected)
            throw Failure.assertion("oversize full export committed")
        } catch XperiencePersistenceFailure.exportTooLarge {}
        try check(store.count == before && store.read(scope: scope) == initialState &&
            store.readHostPreferences(scope: scope) == initialHost, "budget failure altered durable checkpoint")
        try check(facade.isAvailable, "preflight failure incorrectly poisoned checkpoint certainty")
        let accepted = try XperienceExportBudget(completeAccountDocument: .object(["preserved": .string("old")]),
            maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: true)
        let receipt = try await facade.setCapturedHostProfileField(edit.nativeEdit, expected: binding, registry: registry,
            sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
        try check(receipt["value"] == edit.value && store.count == before + 1, "durable receipt missing")
        let saved = try XperienceSavedNamespace.read(field: edit.field, register: receipt)
        let replacement = try saved.replacement(document: document(), label: "Replacement", bindings: [:])
        _ = try await facade.setCapturedHostProfileField(replacement.nativeEdit, expected: binding, registry: registry,
            sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
        let countAfterReplace = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(replacement.nativeEdit, expected: binding, registry: registry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("stale complete register accepted")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(store.count == countAfterReplace, "stale CAS wrote checkpoint")

        // The session checks its ACTUAL candidate host too, not only the facade cache.
        do {
            _ = try await session.dispatch([], now: 1000,
                hostEdits: [.init(profileID: owner, fields: [edit.field: edit.value])],
                hostFieldCAS: .init(profileID: owner, field: edit.field, register: receipt), checkpointValidator: accepted)
            throw Failure.assertion("stale actual-session CAS accepted")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(store.count == countAfterReplace, "actual-session CAS wrote checkpoint")

        // Actual Session's before-edit CAS must reject Unicode-canonical-equivalent evidence.
        // Same clock, actor, keys and structure; ONLY the UTF8 form of the label differs.
        let unicodeScope = VortxAccountScope(account: "synthetic.xperience-unicode-register-cas",
            ownerProfileID: "10000000-0000-0000-0000-000000000074")
        let unicodeKey = SymmetricKey(size: .bits256)
        let unicodeBacking = try VortxEncryptedCheckpointStore(
            directory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("unicode-register-cas"),
            key: unicodeKey)
        let unicodeStore = XperienceCountingCheckpointStore(unicodeBacking)
        let unicodeSession = try VortxNativeSession(scope: unicodeScope, ownerName: "Synthetic", abi: VortxCABI(),
            store: unicodeStore, transport: VortxCResourceTransport(), allowNewAccount: true)
        let unicodeField = "xperience.import.10000000-0000-0000-0000-000000000073"
        let nfc = "\u{00e9}", nfd = "e\u{0301}"
        _ = try await unicodeSession.dispatch([], now: 1000,
            hostEdits: [.init(profileID: unicodeScope.ownerProfileID, fields: [unicodeField: .object(["label": .string(nfd)])])])
        let unicodeHost = try await unicodeSession.hostPreferencesDocument()
        guard let actualUnicodeRegister = unicodeHost["profiles"]?[unicodeScope.ownerProfileID]?["fields"]?[unicodeField] else {
            throw Failure.assertion("Unicode candidate register missing")
        }
        var exactExpected = try actualUnicodeRegister.decode([String: VortxJSON].self)
        exactExpected["value"] = .object(["label": .string(nfc)])
        let expectedNFC = VortxJSON.object(exactExpected)
        try check(expectedNFC == actualUnicodeRegister &&
            !XperienceExactEvidence.json(expectedNFC, actualUnicodeRegister), "actual Unicode fixture lost its negative control")
        let unicodeBefore = unicodeStore.count, unicodeBytesBefore = try unicodeStore.readHostPreferences(scope: unicodeScope)
        do {
            _ = try await unicodeSession.dispatch([], now: 1001,
                hostEdits: [.init(profileID: unicodeScope.ownerProfileID, fields: [unicodeField: .object(["label": .string("must-not-commit")])])],
                hostFieldCAS: .init(profileID: unicodeScope.ownerProfileID, field: unicodeField, register: expectedNFC))
            throw Failure.assertion("actual Session CAS accepted byte-distinct NFC evidence")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(unicodeStore.count == unicodeBefore && unicodeStore.readHostPreferences(scope: unicodeScope) == unicodeBytesBefore,
            "Unicode CAS rejection modified actual encrypted checkpoint")
        await unicodeSession.close()

        // 14 individually valid near-limit imports must NOT bypass whole encrypted document budget.
        // Different IDs avoid the separate identical-import check.
        var hitBudget = false
        for index in 0..<14 {
            var doc = try document(500_000).raw.array!
            var entry = try doc[0].decode([String: VortxJSON].self)
            entry["id"] = .string("large-\(index)"); doc[0] = .object(entry)
            let large = try XperienceImportNamespace.append(document: XperienceCollections.project(.array(doc)),
                label: "Large synthetic", bindings: [:])
            let oldState = try store.read(scope: scope), oldHost = try store.readHostPreferences(scope: scope), oldCount = store.count
            do {
                _ = try await facade.setCapturedHostProfileField(large.nativeEdit, expected: binding, registry: registry,
                    sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            } catch XperiencePersistenceFailure.exportTooLarge {
                hitBudget = true
                try check(store.count == oldCount && store.read(scope: scope) == oldState &&
                    store.readHostPreferences(scope: scope) == oldHost, "aggregate failure pruned or modified checkpoint")
                break
            }
        }
        try check(hitBudget && facade.isAvailable, "aggregate growth did not reject safely")
        try check(try register(facade, profile: owner, field: edit.field)?["value"]?["label"] == .string("Replacement"),
            "existing namespace disappeared during aggregate rejection")
        // Actual A->B->A native selection retires the full profile generation, not just its ID.
        func dispatch(_ action: VortxJSON) async throws {
            try check(facade.dispatch(data: JSONEncoder().encode(VortxJSON.object(["action": .string("Vortx"), "args": action])),
                field: "native_state"), "profile fixture dispatch not admitted")
            await facade.settled()
        }
        let child = "10000000-0000-0000-0000-000000000072"
        try await dispatch(.object(["type": .string("add_profile"), "id": .string(child), "name": .string("Synthetic child")]))
        guard let beforeABA = facade.watchlistBinding, let registryBeforeABA = facade.registryBinding else {
            throw Failure.assertion("ABA fixture binding unavailable")
        }
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(child)]))
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(owner)]))
        try check(facade.watchlistBinding?.profileID == beforeABA.profileID &&
            facade.watchlistBinding?.accountGeneration == beforeABA.accountGeneration &&
            facade.watchlistBinding?.profileGeneration != beforeABA.profileGeneration, "native selection ABA not retired")
        let freshEdit = try XperienceImportNamespace.append(document: document(), label: "Stale ABA", bindings: [:])
        let beforeStale = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(freshEdit.nativeEdit, expected: beforeABA, registry: registryBeforeABA,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("ABA context accepted")
        } catch VortxNativeError.superseded {}
        try check(store.count == beforeStale, "ABA rejection wrote checkpoint")
        let currentBinding = facade.watchlistBinding!, currentRegistry = facade.registryBinding!
        try await facade.rebindRegistry([], expected: currentRegistry)
        try check(facade.capturedHostProfileSnapshot(expected: currentBinding, registry: currentRegistry) == nil,
            "same-descriptor registry ABA accepted old mapping context")
        guard let reboundBinding = facade.watchlistBinding, let reboundRegistry = facade.registryBinding else {
            throw Failure.assertion("rebound context unavailable")
        }
        try check(facade.capturedHostProfileSnapshot(expected: reboundBinding, registry: reboundRegistry) == nil,
            "missing acknowledged host carrier was misrepresented as an empty profile")
        let beforeUnknownHost = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(freshEdit.nativeEdit, expected: reboundBinding, registry: reboundRegistry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("missing acknowledged host carrier admitted a mutation")
        } catch VortxNativeError.invalidSnapshot {}
        try check(store.count == beforeUnknownHost, "unknown host carrier reached durable sink")
        // Republish through the REAL native FIFO, not a synthesized/host-injected cache.
        try await dispatch(.object(["type": .string("get_state")]))
        guard let restoredBinding = facade.watchlistBinding, let restoredRegistry = facade.registryBinding,
              let restored = facade.capturedHostProfileSnapshot(expected: restoredBinding, registry: restoredRegistry) else {
            throw Failure.assertion("real get_state did not restore acknowledged host carrier")
        }
        try check(restored.registers[edit.field]?["value"]?["label"] == .string("Replacement"),
            "rebind/get_state lost existing saved namespace")

        // Cancel AFTER FIFO admission but BEFORE final checkpoint authority enters the latch.
        let gate = XperienceTestGateAuthority()
        let cancellationEdit = try XperienceImportNamespace.append(document: document(), label: "Cancelled", bindings: [:])
        // Use a changed fingerprint so duplicate-import admission is not the rejection reason.
        var cancelRaw = try document().raw.array!, cancelObject = try cancelRaw[0].decode([String: VortxJSON].self)
        cancelObject["id"] = .string("cancel-before-checkpoint"); cancelRaw[0] = .object(cancelObject)
        let cancelEdit = try XperienceImportNamespace.append(document: XperienceCollections.project(.array(cancelRaw)),
            label: "Cancelled", bindings: [:])
        _ = cancellationEdit // prove an unsubmitted draft has no effect
        let cancelBinding = facade.watchlistBinding!, cancelRegistry = facade.registryBinding!, countBeforeCancel = store.count
        let pending = Task {
            try await facade.setCapturedHostProfileField(cancelEdit.nativeEdit, expected: cancelBinding, registry: cancelRegistry,
                sourceAuthority: gate, checkpointValidator: accepted)
        }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.entered.wait(timeout: .now() + 5) == .success) }
        }
        try check(entered, "final checkpoint authority not reached")
        pending.cancel(); gate.release.signal()
        do { _ = try await pending.value; throw Failure.assertion("cancelled final checkpoint committed") }
        catch VortxNativeHostFieldMutationError.cancelled {}
        try check(store.count == countBeforeCancel && (try register(facade, profile: owner, field: cancelEdit.field)) == nil,
            "cancelled transaction reached durable sink")
        // Retiring the STORE/GESTURE lifetime after FIFO admission must also revoke the worker,
        // even when account/profile/registry are unchanged and the task itself was never canceled.
        var retiredRaw = try document().raw.array!, retiredObject = try retiredRaw[0].decode([String: VortxJSON].self)
        retiredObject["id"] = .string("retired-original-gesture"); retiredRaw[0] = .object(retiredObject)
        let retiredEdit = try XperienceImportNamespace.append(document: XperienceCollections.project(.array(retiredRaw)),
            label: "Retired original gesture", bindings: [:])
        let capturedLifetime = XperienceImportLifetime(), retirementGate = XperienceTestGateAuthority(lifetime: capturedLifetime)
        let retirementBinding = facade.watchlistBinding!, retirementRegistry = facade.registryBinding!, beforeRetirement = store.count
        let queuedOriginal = Task {
            try await facade.setCapturedHostProfileField(retiredEdit.nativeEdit, expected: retirementBinding, registry: retirementRegistry,
                sourceAuthority: retirementGate, checkpointValidator: accepted)
        }
        let originalEntered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: retirementGate.entered.wait(timeout: .now() + 5) == .success) }
        }
        try check(originalEntered, "queued original lifetime did not reach final authority")
        capturedLifetime.revoke() // the exact primitive called by Store.invalidate/superseding capture
        let unrelatedNewGestureLifetime = XperienceImportLifetime()
        try check(unrelatedNewGestureLifetime.isActive, "new gesture fixture unavailable")
        retirementGate.release.signal()
        do { _ = try await queuedOriginal.value; throw Failure.assertion("retired original gesture committed") }
        catch XperiencePersistenceFailure.staleContext {}
        try check(store.count == beforeRetirement && (try register(facade, profile: owner, field: retiredEdit.field)) == nil,
            "presentation retirement left a live worker checkpoint authority")
        await facade.shutdown()

        // A REAL encrypted checkpoint may reach disk before a storage/readback error is reported.
        // This isolated synthetic account must stay write-blocked and un-published until reopen.
        let faultScope = VortxAccountScope(account: "synthetic.xperience-post-write-failure",
            ownerProfileID: "10000000-0000-0000-0000-000000000075")
        let faultKey = SymmetricKey(size: .bits256)
        let faultBacking = try VortxEncryptedCheckpointStore(
            directory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("post-write-failure"),
            key: faultKey)
        let faultStore = XperienceCountingCheckpointStore(faultBacking)
        let faultSession = try VortxNativeSession(scope: faultScope, ownerName: "Synthetic", abi: VortxCABI(),
            store: faultStore, transport: VortxCResourceTransport(), allowNewAccount: true)
        let publications = XperiencePublicationCounter()
        let faultFacade = try await VortxNativeCoreFacade.create(session: faultSession, registry: faultSession.resourceRegistry(),
            changed: { _ in publications.record() })
        guard let faultBinding = faultFacade.watchlistBinding, let faultRegistry = faultFacade.registryBinding,
              let projectedBefore = faultFacade.stateData("native_host_preferences"),
              let stateBefore = faultFacade.stateData("native_state") else { throw Failure.assertion("fault fixture unavailable") }
        let faultEdit = try XperienceImportNamespace.append(document: document(), label: "Durable but not acknowledged", bindings: [:])
        let beforeFault = faultStore.count, beforePublications = publications.count
        faultStore.armPostWriteFailure()
        do {
            _ = try await faultFacade.setCapturedHostProfileField(faultEdit.nativeEdit, expected: faultBinding, registry: faultRegistry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("post-write failure returned a successful receipt")
        } catch VortxNativeError.checkpointUncertain {}
        guard let diskHostBytes = try faultStore.readHostPreferences(scope: faultScope),
              let projectedAfter = faultFacade.stateData("native_host_preferences"),
              let stateAfter = faultFacade.stateData("native_state") else { throw Failure.assertion("fault readback unavailable") }
        let diskHost = try JSONDecoder().decode(VortxJSON.self, from: diskHostBytes)
        try check(faultStore.injectedFailureCount == 1 && faultStore.count == beforeFault + 1 &&
            VortxNativeHostFieldEvidence.json(diskHost["document"]?["profiles"]?[faultScope.ownerProfileID]?["fields"]?[faultEdit.field]?["value"], faultEdit.value),
            "injected error did not follow an actual durable encrypted write/readback")
        try check(faultFacade.requiresCheckpointReopen && !faultFacade.isAvailable &&
            faultFacade.lastFailure == "checkpoint_uncertain_reopen_required", "uncertain checkpoint was not fenced")
        try check(publications.count == beforePublications &&
            VortxNativeHostFieldEvidence.json(try JSONDecoder().decode(VortxJSON.self, from: projectedBefore),
                try JSONDecoder().decode(VortxJSON.self, from: projectedAfter)) &&
            VortxNativeHostFieldEvidence.json(try JSONDecoder().decode(VortxJSON.self, from: stateBefore),
                try JSONDecoder().decode(VortxJSON.self, from: stateAfter)),
            "uncertain checkpoint published an unacknowledged new projection")
        let afterFault = faultStore.count
        do {
            _ = try await faultSession.dispatch([], now: 2000,
                hostEdits: [.init(profileID: faultScope.ownerProfileID, fields: ["synthetic.afterFault": .bool(true)])])
            throw Failure.assertion("session admitted mutation before checkpoint reopen")
        } catch VortxNativeError.checkpointUncertain {}
        do {
            _ = try await faultFacade.setCapturedHostProfileField(faultEdit.nativeEdit, expected: faultBinding, registry: faultRegistry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("facade admitted mutation before checkpoint reopen")
        } catch VortxNativeError.superseded {}
        try check(faultStore.count == afterFault && publications.count == beforePublications,
            "blocked post-failure mutation reached durable sink/publication")
        await faultFacade.shutdown() // release the real scope-account writer before reopening
        let reopenedSession = try VortxNativeSession(scope: faultScope, ownerName: "Synthetic", abi: VortxCABI(),
            store: faultStore, transport: VortxCResourceTransport())
        let reopenedFacade = try await VortxNativeCoreFacade.create(session: reopenedSession, registry: reopenedSession.resourceRegistry(),
            changed: { _ in })
        guard let reopenedBinding = reopenedFacade.watchlistBinding, let reopenedRegistry = reopenedFacade.registryBinding,
              let reopenedRegister = try register(reopenedFacade, profile: faultScope.ownerProfileID, field: faultEdit.field) else {
            throw Failure.assertion("authenticated reopen did not recover durable uncertain checkpoint")
        }
        try check(reopenedFacade.isAvailable && !reopenedFacade.requiresCheckpointReopen &&
            VortxNativeHostFieldEvidence.json(reopenedRegister["value"], faultEdit.value), "reopen did not certify durable value")
        let recovered = try XperienceSavedNamespace.read(field: faultEdit.field, register: reopenedRegister)
        let afterReopenEdit = try recovered.replacement(document: document(), label: "Reopened acknowledged", bindings: [:])
        let countAfterReopen = faultStore.count
        let afterReopenReceipt = try await reopenedFacade.setCapturedHostProfileField(afterReopenEdit.nativeEdit,
            expected: reopenedBinding, registry: reopenedRegistry, sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
        try check(faultStore.count == countAfterReopen + 1 &&
            VortxNativeHostFieldEvidence.json(afterReopenReceipt["value"], afterReopenEdit.value),
            "validated reopen did not permit a subsequent acknowledged mutation")
        await reopenedFacade.shutdown()
        print("PASS actual native CAS/budget/ABA/registry/unknown-carrier/cancellation/lifetime/preflight/postwrite-reopen")
    }
    static func main() async {
        do { try await run() } catch { print("FAIL Xperience native checkpoint components"); exit(1) }
    }
}
