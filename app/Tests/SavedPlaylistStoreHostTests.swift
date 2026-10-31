import Darwin
import Foundation

// Runs the FULL production Store against explicitly synthetic collaborators. No SwiftUI,
// Keychain, native ABI, account, checkpoint, filesystem persistence or network is involved.
@main @MainActor private enum SavedPlaylistStoreHostTests {
    private static let store = SavedPlaylistStore.shared
    private static let core = CoreBridge.shared
    private static let sync = VortXSyncManager.shared
    private static let queue = PlaybackTitleQueue.shared
    private static let profileA = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let profileB = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private static let accountA = "account.store-host-fixture.A"
    private static let accountB = "account.store-host-fixture.B"

    private struct Assertion: Error { let message: String }
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Assertion(message: message) }
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Assertion(message: message) }
        return value
    }
    private static func until(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard clock.now < deadline else { throw PlaylistStoreFixtureFailure.timeout(label) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private static func candidate(_ index: Int) -> PlaybackTitleQueuePolicy.Candidate {
        PlaybackTitleQueuePolicy.Candidate(contentID: "tt-store-fixture-\(index)", type: "movie",
            title: "Store fixture \(index)")!
    }
    private static func document(_ name: String, count: Int = 2, id: UUID = UUID()) -> VortxNativePlaylist.Document {
        .init(id: id, name: name, entries: (0..<count).map { .init(id: UUID(), candidate: candidate($0)) })
    }
    private static func selectA() { core.select(namespace: accountA, profile: profileA) }
    private static func selectB() { core.select(namespace: accountB, profile: profileB) }
    private static func loaded() async throws {
        try await until("Store load") { !store.isLoading && store.canBrowseCurrentProfile }
    }
    private static func cleanupDrafts() async throws {
        // Only public Store APIs clear test drafts. Reopening the same stable scope exposes
        // old-generation drafts for discard, but never makes them writable again.
        for isA in [true, false] {
            if isA { selectA() } else { selectB() }
            store.profileBoundaryWillChange()
            queue.configure(candidates: [])
            store.open()
            try await loaded()
            for draft in store.visibleDrafts { store.discardDraft(draft.id) }
            try check(store.visibleDrafts.isEmpty, "fixture cleanup left a draft")
        }
        store.profileBoundaryWillChange()
    }
    private static func fresh(seed: VortxNativePlaylist.Document? = nil) async throws -> String? {
        try await cleanupDrafts()
        core.reset()
        sync.reset()
        selectA()
        queue.configure(candidates: [candidate(8), candidate(9)])
        let field = try seed.map { try core.seed($0) }
        store.open()
        try await loaded()
        core.resetCounters()
        return field
    }
    private static func generation() throws -> UUID {
        try required(store.currentOwnerGeneration, "missing captured Store generation")
    }
    private static func reopenA() async throws {
        selectA()
        store.profileBoundaryWillChange()
        queue.configure(candidates: [candidate(8), candidate(9)])
        store.open()
        try await loaded()
    }

    private static func preparedGestureCannotFollowB() async throws {
        let original = document("Original A")
        let field = try required(try await fresh(seed: original), "seed field")
        let oldGeneration = try generation()
        let originalRecord = try required(store.record(field: field), "original detail")
        let intent = try required(store.prepareSaveCurrentQueue(named: "Prepared under A"), "prepared intent")
        selectB()
        store.profileBoundaryWillChange()
        _ = try core.seed(document("Foreign B", id: original.id))
        queue.configure(candidates: [])
        store.open()
        try await loaded()
        let beforeB = core.fieldsForCurrentOwner()
        await store.perform(intent)
        try check(core.saveCalls == 0 && core.fieldsForCurrentOwner() == beforeB, "old prepared gesture wrote B")
        try check(store.visibleDrafts.isEmpty, "A draft leaked into B")
        store.addToQueue(record: originalRecord, ownerGeneration: oldGeneration)
        try check(queue.appendCalls == 0 && queue.policy.count == 0, "old detail routed into B queue")
        try await reopenA()
        let retained = try required(store.visibleDrafts.first, "A draft not retained")
        try check(retained.document?.name == "Prepared under A" && !store.canContinueDraft(retained.id),
            "reopen transferred an old-generation draft's authority")
    }

    private static func retirementDuringBudget() async throws {
        _ = try await fresh()
        let intent = try required(store.prepareSaveCurrentQueue(named: "Budget suspension"), "budget intent")
        core.budgetGate.arm()
        let saving = Task { @MainActor in await store.perform(intent) }
        try await until("budget entered") { core.budgetGate.entered }
        selectB()
        store.profileBoundaryWillChange()
        core.budgetGate.release()
        await saving.value
        try check(core.saveCalls == 0 && core.fieldsForCurrentOwner().isEmpty, "retired budget permitted a write")
        try check(!store.cloudStatusText.contains("saved in cloud"), "retired budget published cloud success")
        try await reopenA()
        try check(store.visibleDrafts.count == 1, "budget retirement lost its scoped draft")
    }

    private static func retirementDuringCommittedReply() async throws {
        _ = try await fresh()
        let intent = try required(store.prepareSaveCurrentQueue(named: "Committed under A"), "CAS intent")
        core.saveReplyGate.arm()
        let saving = Task { @MainActor in await store.perform(intent) }
        try await until("committed response held") { core.saveReplyGate.entered }
        try check(core.writes.count == 1 && core.writes[0].owner.credentialNamespace == accountA,
            "synthetic commit did not belong to original A")
        selectB()
        store.profileBoundaryWillChange()
        core.saveReplyGate.release()
        await saving.value
        try check(core.writes.count == 1 && core.fieldsForCurrentOwner().isEmpty, "late A reply changed B")
        try check(store.visibleRecords.isEmpty && !store.cloudStatusText.contains("saved in cloud"),
            "late accepted reply published under retired target")
        try await reopenA()
        try check(store.visibleDrafts.count == 1, "ambiguous late commit lost recovery draft")
    }

    private static func retirementDuringRealFingerprint() async throws {
        _ = try await fresh()
        let intent = try required(store.prepareSaveCurrentQueue(named: "Fingerprint suspension"), "fingerprint intent")
        let barrier = PlaylistStoreFingerprintBarrier()
        let hold = Task { await NativePlaylistCloudReceiptProjectionWorker.shared.hostFixtureHoldExecutor(barrier) }
        defer { barrier.release() }
        let entered = await barrier.waitUntilEntered()
        try check(entered, "real fingerprint actor barrier did not enter")
        let saving = Task { @MainActor in await store.perform(intent) }
        // The synchronous Store readback immediately precedes its real actor fingerprint call.
        // Once the MainActor can observe this count, that call is queued behind the barrier.
        try await until("Store readback before fingerprint") { core.registerReads == 1 }
        selectB()
        store.profileBoundaryWillChange()
        barrier.release()
        await hold.value
        await saving.value
        try check(core.writes.count == 1 && core.fieldsForCurrentOwner().isEmpty, "fingerprint crossed owner")
        try check(!store.cloudStatusText.contains("saved in cloud"), "late real fingerprint published success")
        try await reopenA()
        try check(store.visibleDrafts.count == 1, "fingerprint retirement lost scoped draft")
    }

    private static func conflictCopyAndTombstone() async throws {
        let original = document("Original")
        let field = try required(try await fresh(seed: original), "conflict field")
        let ownerGeneration = try generation()
        let observed = try required(store.record(field: field), "original record")
        let originalRegister = observed.register
        let rename = try required(store.prepareRename(record: observed, to: "My rename",
            ownerGeneration: ownerGeneration), "rename intent")
        let earlierDelete = try required(store.prepareDelete(record: observed,
            ownerGeneration: ownerGeneration), "observed delete intent")
        try core.peerReplace(document("Peer changed", id: original.id))
        await store.perform(rename)
        try check(core.writes.isEmpty, "stale raw CAS overwrote peer")
        let draft = try required(store.visibleDrafts.first, "conflict draft")
        try check(draft.expectedRegister == originalRegister && draft.document?.name == "My rename",
            "conflict draft lost exact original input")
        store.reloadKeepingDraft(draft.id)
        try await loaded()
        try check(store.record(field: field)?.document?.name == "Peer changed" && store.draft(draft.id) == draft,
            "reload discarded draft or concealed peer")
        try check(store.prepareDelete(record: observed, ownerGeneration: ownerGeneration) == nil,
            "stale observed delete adopted a refreshed same-field record")
        try check(store.prepareRename(record: observed, to: "Stale detail", ownerGeneration: ownerGeneration) == nil,
            "stale observed rename adopted a refreshed same-field record")
        try check(store.prepareReplaceFromCurrentQueue(record: observed, ownerGeneration: ownerGeneration) == nil,
            "stale observed replace adopted a refreshed same-field record")
        let queueCalls = queue.appendCalls
        store.addToQueue(record: observed, ownerGeneration: ownerGeneration)
        try check(queue.appendCalls == queueCalls, "stale observed queue action reached queue")
        await store.perform(earlierDelete)
        try check(core.writes.isEmpty && core.fieldsForCurrentOwner()[field]?["value"] != .null,
            "delete confirmed after peer refresh overwrote newer register")
        let deleteDraft = try required(store.visibleDrafts.first { $0.operation == .delete }, "delete conflict draft")
        store.discardDraft(deleteDraft.id)
        let copy = try required(store.prepareSaveAsCopy(draftID: draft.id,
            ownerGeneration: ownerGeneration), "save-as-copy intent")
        await store.perform(copy)
        try await loaded()
        let copied = try required(store.visibleRecords.first { $0.document?.name == "My rename" }, "saved copy")
        let copiedDocument = try required(copied.document, "copied document")
        try check(copiedDocument.id != original.id && Set(copiedDocument.entries.map(\.id)).isDisjoint(with: original.entries.map(\.id)),
            "copy reused original durable document/entry IDs")
        try check(store.draft(draft.id) == nil && store.visibleRecords.count == 2, "copy did not conserve original/remove draft")
        let oldRename = try required(store.prepareRename(record: copied, to: "Must not resurrect",
            ownerGeneration: ownerGeneration), "old rename")
        let deletion = try required(store.prepareDelete(record: copied,
            ownerGeneration: ownerGeneration), "delete intent")
        await store.perform(deletion)
        try await loaded()
        let writesBeforeStale = core.writes.count
        await store.perform(oldRename)
        try check(core.writes.count == writesBeforeStale && core.fieldsForCurrentOwner()[copied.field]?["value"] == .null,
            "stale rename resurrected tombstone")
        try check(store.record(field: copied.field) == nil && store.visibleDrafts.count == 1,
            "tombstone projection or recovery draft incorrect")
    }

    private static func inFlightDiscardAndDraftCapacity() async throws {
        _ = try await fresh()
        core.rejectBudget = true
        core.budgetGate.arm()
        let first = try required(store.prepareSaveCurrentQueue(named: "In flight"), "first draft intent")
        let saving = Task { @MainActor in await store.perform(first) }
        try await until("draft in flight") { core.budgetGate.entered }
        let inFlight = try required(store.visibleDrafts.first, "in-flight draft")
        try check(store.isDraftSaving(inFlight.id), "saving draft not marked")
        store.discardDraft(inFlight.id)
        try check(store.draft(inFlight.id) != nil, "discard removed in-flight work")
        core.budgetGate.release()
        await saving.value
        for index in 1..<32 {
            let intent = try required(store.prepareSaveCurrentQueue(named: "Retained \(index)"), "retained intent")
            await store.perform(intent)
        }
        let ids = Set(store.visibleDrafts.map(\.id))
        try check(ids.count == 32, "expected bounded retained drafts")
        let callsBefore = core.budgetCalls
        let overflow = try required(store.prepareSaveCurrentQueue(named: "Overflow"), "overflow intent")
        await store.perform(overflow)
        try check(Set(store.visibleDrafts.map(\.id)) == ids && core.budgetCalls == callsBefore && core.saveCalls == 0,
            "draft capacity attempted work or evicted another draft")
    }

    private static func cancellationRetainsDraft() async throws {
        _ = try await fresh()
        let intent = try required(store.prepareSaveCurrentQueue(named: "Canceled"), "cancel intent")
        core.budgetGate.arm()
        let saving = Task { @MainActor in await store.perform(intent) }
        try await until("cancel budget entered") { core.budgetGate.entered }
        saving.cancel()
        core.budgetGate.release()
        await saving.value
        let draft = try required(store.visibleDrafts.first, "canceled draft")
        try check(core.saveCalls == 0 && !store.isDraftSaving(draft.id), "canceled budget started save or stayed busy")
        try check(queue.policy.count == 2, "cancellation changed queue")
    }

    private static func receiptTokensAndRefresh() async throws {
        let field = try required(try await fresh(seed: document("Receipt record")), "receipt field")
        let ownerGeneration = try generation()
        let owner = try required(core.owner, "receipt owner")
        let register = try required(store.record(field: field)?.register, "receipt register")
        sync.register(owner: owner, field: field, register: register)
        let oldToken = try required(store.beginReceiptObservation(field: field, ownerGeneration: ownerGeneration), "old token")
        let currentToken = try required(store.beginReceiptObservation(field: field, ownerGeneration: ownerGeneration), "new token")
        store.endReceiptObservation(field: field, ownerGeneration: ownerGeneration, token: oldToken)
        try await until("pending receipt") { store.receiptState(field: field, ownerGeneration: ownerGeneration) == .pending }
        store.nativePlaylistChangeDidOccur()
        try await loaded()
        sync.acknowledgeAll(version: 7)
        store.cloudReceiptRevisionDidChange()
        try check(store.receiptState(field: field, ownerGeneration: ownerGeneration) == .saved(version: 7),
            "current observation did not see exact accepted receipt")
        store.endReceiptObservation(field: field, ownerGeneration: ownerGeneration, token: oldToken)
        sync.forgetReceipts()
        store.cloudReceiptRevisionDidChange()
        try check(store.receiptState(field: field, ownerGeneration: ownerGeneration) == .unknown,
            "forgotten volatile receipt stayed saved")
        store.endReceiptObservation(field: field, ownerGeneration: ownerGeneration, token: currentToken)
        let queries = sync.queryCount
        store.cloudReceiptRevisionDidChange()
        try check(sync.queryCount == queries, "refresh/old teardown prevented exact current-token teardown")
    }

    private static func hintCoalescingAndCanceledLoad() async throws {
        _ = try await fresh(seed: document("A rows"))
        store.reloadFromUserGesture()
        try check(store.isLoading && core.registerReads == 1, "reload did not start one captured read")
        for _ in 0..<20 { store.nativePlaylistChangeDidOccur() }
        try check(core.registerReads == 1, "in-flight hints were not coalesced")
        try await loaded()
        try check(core.registerReads == 2, "coalesced hints did not produce exactly one follow-up read")
        store.reloadFromUserGesture()
        selectB()
        store.profileBoundaryWillChange()
        _ = try core.seed(document("B rows"))
        queue.configure(candidates: [])
        store.open()
        try await loaded()
        try check(store.visibleRecords.count == 1 && store.visibleRecords[0].document?.name == "B rows",
            "canceled old load replaced successor rows")
    }

    private static func queueAdmissionIsConservative() async throws {
        let field = try required(try await fresh(seed: document("Two titles")), "queue field")
        queue.configure(candidates: (0..<99).map { candidate($0) })
        let before = queue.policy.durableEntries
        let record = try required(store.record(field: field), "queue record")
        store.addToQueue(record: record, ownerGeneration: try generation())
        try check(queue.appendCalls == 1 && queue.policy.durableEntries == before && core.writes.isEmpty,
            "failed queue admission changed queue/native source")
        // This collaborator only supplies capture/snapshot/append. Actual queue routing,
        // autoplay, persistence and playback are deliberately outside this Store fixture.
    }

    private static func run(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
        try await body()
        print("PASS \(name)")
    }
    static func main() async {
        do {
            try await run("prepared original owner and stale detail") { try await preparedGestureCannotFollowB() }
            try await run("owner retirement during budget") { try await retirementDuringBudget() }
            try await run("owner retirement during committed reply") { try await retirementDuringCommittedReply() }
            try await run("owner retirement during actual fingerprint") { try await retirementDuringRealFingerprint() }
            try await run("raw CAS, fresh copy and tombstone") { try await conflictCopyAndTombstone() }
            try await run("in-flight discard and 32-draft bound") { try await inFlightDiscardAndDraftCapacity() }
            try await run("task cancellation retains scoped draft") { try await cancellationRetainsDraft() }
            try await run("pending/saved/unknown and exact observer tokens") { try await receiptTokensAndRefresh() }
            try await run("hint coalescing and canceled old load") { try await hintCoalescingAndCanceledLoad() }
            try await run("Store queue admission conservation") { try await queueAdmissionIsConservative() }
            try await cleanupDrafts()
            print("PASS 10 actual-Store host fixture groups; synthetic authority/transport, no native/UI/cloud proof")
        } catch {
            print("FAIL actual-Store host fixture: \(error)")
            exit(1)
        }
    }
}
