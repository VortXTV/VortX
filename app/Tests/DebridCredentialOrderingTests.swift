// Standalone executable gate over the production credential state and persistence primitives.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
//     -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/Keychain.swift \
//     app/SourcesShared/DebridCredentialState.swift \
//     app/Tests/DebridCredentialOrderingTests.swift \
//     -o /tmp/debrid-credential-ordering && /tmp/debrid-credential-ordering
//
// The suite never touches the live Keychain. Every failure and crash position uses an isolated memory driver.

import Foundation

private struct Results {
    private(set) var passed = 0
    private(set) var failed: [String] = []

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed.append(message)
            print("FAIL  \(message)")
        }
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return messages.isEmpty
    }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setTrue() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class TorBoxContributorProbe {
    private let credentialStore: DebridCredentialSnapshotStore
    private var credentialObserver: DebridCredentialNotificationToken?
    var credentialRevision: UInt64?
    var inFlightKey: String?
    var inFlightRevision: UInt64?
    var cache: [String: [String]] = [:]
    var cooldown = false
    var shownKey: String?
    var publishedContentID: String?
    var visible: [String] = []

    init(credentialStore: DebridCredentialSnapshotStore) {
        self.credentialStore = credentialStore
        credentialRevision = credentialStore.load().revision
        credentialObserver = DebridCredentialNotificationToken(
            NotificationCenter.default.addObserver(
                forName: DebridCredentialSnapshotStore.didPublishNotification,
                object: credentialStore,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    _ = self.adopt(self.credentialStore.load().revision)
                }
            }
        )
    }

    func adopt(_ revision: UInt64) -> Bool {
        credentialStore.compareAndPublish(revision: revision) {
            guard self.credentialRevision != revision else { return }
            self.credentialRevision = revision
            self.inFlightKey = nil
            self.inFlightRevision = nil
            self.cache.removeAll()
            self.cooldown = false
            self.shownKey = nil
            self.publishedContentID = nil
            self.visible = []
        }
    }

}

@MainActor
private final class CacheAwarenessProbe {
    private let credentialStore: DebridCredentialSnapshotStore
    private var credentialObserver: DebridCredentialNotificationToken?
    var credentialRevision: UInt64?
    var lastHashes: Set<String> = []
    var lastUsenet: Set<String> = []
    var cachedHashes: Set<String> = []
    var cachedUsenet: Set<String> = []

    init(credentialStore: DebridCredentialSnapshotStore) {
        self.credentialStore = credentialStore
        credentialRevision = credentialStore.load().revision
        credentialObserver = DebridCredentialNotificationToken(
            NotificationCenter.default.addObserver(
                forName: DebridCredentialSnapshotStore.didPublishNotification,
                object: credentialStore,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    _ = self.adopt(
                        self.credentialStore.load().revision,
                        store: self.credentialStore
                    )
                }
            }
        )
    }

    func adopt(_ revision: UInt64, store: DebridCredentialSnapshotStore) -> Bool {
        store.compareAndPublish(revision: revision) {
            guard self.credentialRevision != revision else { return }
            self.credentialRevision = revision
            self.lastHashes.removeAll()
            self.lastUsenet.removeAll()
            self.cachedHashes.removeAll()
            self.cachedUsenet.removeAll()
        }
    }
}

private final class MemoryCredentialStorage {
    var values: [String: String] = [:]
    var failWrites: Set<String> = []
    var corruptWrites: Set<String> = []
    var failWriteCalls: Set<Int> = []
    var corruptWriteCalls: Set<Int> = []
    var failDeletes: Set<String> = []
    var failReadCalls: Set<Int> = []
    private(set) var readCallCount = 0
    private(set) var writeCallCount = 0

    func read(_ account: String) -> String? {
        readCallCount += 1
        if failReadCalls.remove(readCallCount) != nil { return nil }
        return values[account]
    }

    func resetReadSchedule() {
        readCallCount = 0
        failReadCalls.removeAll()
    }

    func resetWriteSchedule() {
        writeCallCount = 0
        failWriteCalls.removeAll()
        corruptWriteCalls.removeAll()
    }

    func write(_ value: String, _ account: String) -> Bool {
        writeCallCount += 1
        guard !failWrites.contains(account), failWriteCalls.remove(writeCallCount) == nil else {
            return false
        }
        let corrupt = corruptWrites.contains(account) || corruptWriteCalls.remove(writeCallCount) != nil
        values[account] = corrupt ? "corrupt" : value
        return true
    }

    func delete(_ account: String) -> Bool {
        guard !failDeletes.contains(account) else { return false }
        values.removeValue(forKey: account)
        return true
    }

    var io: DebridCredentialStorageIO {
        DebridCredentialStorageIO(read: read, write: write, delete: delete)
    }
}

private let accountAString = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let accountBString = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private let accountA = UUID(uuidString: accountAString)!
private let accountB = UUID(uuidString: accountBString)!
private let ownerA = DebridOwnerScope.account(accountA)
private let ownerB = DebridOwnerScope.account(accountB)

private func snapshot(
    _ owner: DebridOwnerScope,
    _ revision: UInt64,
    _ keys: [DebridService: String] = [:]
) -> DebridCredentialSnapshot {
    DebridCredentialSnapshot(owner: owner, revision: revision, keys: keys)
}

private func committedKeys(
    _ storage: MemoryCredentialStorage,
    owner: DebridOwnerScope
) -> [DebridService: String] {
    DebridCredentialPersistence.committedKeys(owner: owner, read: storage.read)
}

private func commit(
    _ storage: MemoryCredentialStorage,
    owner: DebridOwnerScope,
    keys: [DebridService: String]
) -> DebridCredentialCommitResult {
    DebridCredentialPersistence.commit(owner: owner, keys: keys, io: storage.io)
}

private func migrate(
    _ storage: MemoryCredentialStorage,
    owner: DebridOwnerScope,
    service: DebridService,
    source: String,
    claim: String?
) -> DebridCredentialMigrationResult {
    DebridCredentialMigration.migrate(
        service: service,
        owner: owner,
        sourceAccount: source,
        claimAccount: claim,
        targetKeys: { committedKeys(storage, owner: owner) },
        commitTarget: { commit(storage, owner: owner, keys: $0).succeeded },
        read: storage.read,
        write: storage.write,
        delete: storage.delete
    )
}

private func testOwnerGrammar(_ results: inout Results) {
    results.expect(DebridOwnerScope.canonicalAccount(accountAString) == ownerA,
                   "lowercase server UUID is a canonical account owner")
    results.expect(DebridOwnerScope.canonicalAccount(accountAString.uppercased()) == nil,
                   "uppercase UUID-like owner remains noncanonical and unmigrated")
    results.expect(DebridOwnerScope.canonicalAccount("{\(accountAString)}") == nil,
                   "braced UUID-like owner remains noncanonical and unmigrated")
    results.expect(DebridOwnerScope.canonicalAccount("") == nil,
                   "empty signed-in owner is rejected rather than mapped to signed out")
    results.expect(DebridOwnerScope.canonicalAccount("local") == nil,
                   "literal local cannot become a signed-in namespace")
    results.expect(DebridOwnerScope.signedOutDevice.storageNamespace != ownerA.storageNamespace,
                   "signed-out and account storage namespaces are disjoint")
    results.expect(DebridService.torBox.keychainAccount(owner: .signedOutDevice)
                   == "vortx.debrid.torBox.local",
                   "old local slot stays permanently device-local")
    results.expect(DebridCredentialStorageAccounts(owner: ownerA)
                   != DebridCredentialStorageAccounts(owner: ownerB),
                   "atomic envelope accounts are owner scoped")
}

private func testRevisionOrdering(_ results: inout Results) {
    let a1 = snapshot(ownerA, 1, [.realDebrid: "a1"])
    let signedOut2 = snapshot(.signedOutDevice, 2)
    let b3 = snapshot(ownerB, 3, [.torBox: "b3"])
    let orders = [
        [a1, signedOut2, b3], [a1, b3, signedOut2], [signedOut2, a1, b3],
        [signedOut2, b3, a1], [b3, a1, signedOut2], [b3, signedOut2, a1],
    ]
    for (index, order) in orders.enumerated() {
        var fence = DebridCredentialRevisionFence()
        var accepted: DebridCredentialSnapshot?
        for candidate in order where fence.accept(candidate) { accepted = candidate }
        results.expect(accepted == b3, "adverse delivery order \(index + 1) leaves B revision 3 final")
    }

    var fence = DebridCredentialRevisionFence()
    results.expect(fence.accept(b3), "first delivered snapshot is accepted")
    results.expect(!fence.accept(b3), "equal revision never rebuilds resolvers")
    results.expect(!fence.accept(signedOut2), "older revision never rebuilds resolvers")
}

private func testMutableState(_ results: inout Results) {
    var state = DebridCredentialMutableState(owner: .signedOutDevice,
                                             keys: [.realDebrid: "local-a"])
    results.expect(state.snapshot.revision == 1 && state.owner == .signedOutDevice,
                   "relaunch without session publishes device-local revision 1")

    let boundA = state.replace(owner: ownerA, keys: [.realDebrid: "account-a"])
    results.expect(boundA?.revision == 2 && boundA?.owner == ownerA,
                   "restored-account bind advances owner and key revision once")
    let edit = state.setKey("newest", for: .realDebrid)
    results.expect(edit?.revision == 3 && edit?.keys[.realDebrid] == "newest",
                   "one local key edit advances exactly one revision")
    results.expect(state.setKey("newest", for: .realDebrid) == nil,
                   "idempotent local edit publishes no duplicate revision")

    let beforeRemote = state.revision
    let remote = state.applyRemoteKeys([.allDebrid: "ad", .premiumize: "pm", .torBox: "tb"])
    results.expect(remote?.revision == beforeRemote + 1,
                   "four-service remote apply advances exactly one revision")
    results.expect(remote?.keys == [
        .realDebrid: "newest", .allDebrid: "ad", .premiumize: "pm", .torBox: "tb",
    ], "remote apply produces one complete in-memory envelope")
}

@MainActor
private func testRequestAndPublicationFences(_ results: inout Results) {
    let a1 = snapshot(ownerA, 1, [.realDebrid: "a"])
    let b2 = snapshot(ownerB, 2, [.torBox: "b"])

    let queuedStore = DebridCredentialSnapshotStore(initial: a1)
    let queuedToken = DebridCredentialRevisionToken(revision: 1, store: queuedStore)
    let reachedIssueBoundary = DispatchSemaphore(value: 0)
    let allowAuthorization = DispatchSemaphore(value: 0)
    let queuedDone = DispatchSemaphore(value: 0)
    let queuedIssued = BoolBox()
    let queuedAccepted = BoolBox()
    DispatchQueue(label: "vortx.debrid.issue.queued-a").async {
        reachedIssueBoundary.signal()
        allowAuthorization.wait()
        if queuedToken.authorizeAndIssue({ queuedIssued.setTrue() }) { queuedAccepted.setTrue() }
        queuedDone.signal()
    }
    reachedIssueBoundary.wait()
    let insecurePrecheck = queuedStore.isCurrent(revision: 1)
    results.expect(insecurePrecheck, "control predicate passes while A is paused before task resume")
    results.expect(queuedStore.publish(b2), "B publishes while A is paused at the issue boundary")
    allowAuthorization.signal()
    queuedDone.wait()
    results.expect(!queuedAccepted.current && !queuedIssued.current,
                   "B-first ordering rejects A without ever resuming its request")
    let insecureIssue = BoolBox()
    if insecurePrecheck { insecureIssue.setTrue() }
    results.expect(insecureIssue.current,
                   "control proves a detached pre-send predicate would issue stale A after B")

    let multiStore = DebridCredentialSnapshotStore(initial: a1)
    let multiToken = DebridCredentialRevisionToken(revision: 1, store: multiStore)
    let firstIssued = BoolBox()
    results.expect(multiToken.authorizeAndIssue({ firstIssued.setTrue() }) && firstIssued.current,
                   "first request in a multi-await flow resumes while A is current")
    results.expect(multiStore.publish(b2), "B publishes between provider awaits")
    let laterIssued = BoolBox()
    results.expect(!multiToken.authorizeAndIssue({ laterIssued.setTrue() }) && !laterIssued.current,
                   "later request in the same multi-await flow never resumes stale A")

    let issuedFirstStore = DebridCredentialSnapshotStore(initial: a1)
    let issuedFirstToken = DebridCredentialRevisionToken(revision: 1, store: issuedFirstStore)
    let issueClosureEntered = DispatchSemaphore(value: 0)
    let allowResume = DispatchSemaphore(value: 0)
    let issuedFirst = BoolBox()
    let issueDone = DispatchSemaphore(value: 0)
    DispatchQueue(label: "vortx.debrid.issue.a-first").async {
        _ = issuedFirstToken.authorizeAndIssue {
            issueClosureEntered.signal()
            allowResume.wait()
            issuedFirst.setTrue()
        }
        issueDone.signal()
    }
    issueClosureEntered.wait()
    let publishStarted = DispatchSemaphore(value: 0)
    let releaseObservedBlockedIssue = DispatchSemaphore(value: 0)
    let publicationWaited = BoolBox()
    DispatchQueue(label: "vortx.debrid.issue.release-a").async {
        publishStarted.wait()
        if issueDone.wait(timeout: .now() + 0.05) == .timedOut { publicationWaited.setTrue() }
        allowResume.signal()
        releaseObservedBlockedIssue.signal()
    }
    publishStarted.signal()
    let bPublishedAfterIssue = issuedFirstStore.publish(b2)
    issueDone.wait()
    releaseObservedBlockedIssue.wait()
    results.expect(publicationWaited.current,
                   "B publication waits while A is paused exactly before request resume")
    results.expect(bPublishedAfterIssue && issuedFirst.current && issuedFirstStore.load() == b2,
                   "A-first ordering resumes the already-issued transport before B publishes")

    let publicationStore = DebridCredentialSnapshotStore(initial: a1)
    let published = BoolBox()
    results.expect(publicationStore.isCurrent(revision: 1),
                   "A's old non-atomic precheck passes before B")
    results.expect(publicationStore.publish(b2), "B wins between A's precheck and caller mutation")
    results.expect(!publicationStore.compareAndPublish(revision: 1) { published.setTrue() },
                   "atomic compare-and-publish rejects A after B wins")
    results.expect(!published.current, "stale A performs no caller mutation")

    let serializedStore = DebridCredentialSnapshotStore(initial: a1)
    let mutationDone = BoolBox()
    let reentrantRead = BoolBox()
    let aAccepted = serializedStore.compareAndPublish(revision: 1) {
        if serializedStore.load() == a1 { reentrantRead.setTrue() }
        mutationDone.setTrue()
    }
    results.expect(aAccepted && mutationDone.current,
                   "A-first caller mutation completes synchronously on MainActor")
    results.expect(reentrantRead.current,
                   "an observable callback can re-enter snapshot reads without deadlocking")
    results.expect(serializedStore.publish(b2) && serializedStore.load() == b2,
                   "accepted A mutation completes before later B publication")
}

@MainActor
private func testTorBoxTwoLegAndStateSchedules(_ results: inout Results) async {
    let a1 = snapshot(ownerA, 1, [.torBox: "a"])
    let b2 = snapshot(ownerB, 2, [.torBox: "b"])

    let bFirstStore = DebridCredentialSnapshotStore(initial: a1)
    let bFirstToken = DebridCredentialRevisionToken(revision: 1, store: bFirstStore)
    results.expect(bFirstStore.publish(b2), "TorBox B publishes before either independent search send")
    let staleUsenet = BoolBox()
    let staleTorrent = BoolBox()
    results.expect(!bFirstToken.authorizeAndIssue({ staleUsenet.setTrue() }) && !staleUsenet.current,
                   "TorBox stale usenet task never resumes after B")
    results.expect(!bFirstToken.authorizeAndIssue({ staleTorrent.setTrue() }) && !staleTorrent.current,
                   "TorBox stale torrent task never resumes after B")

    let splitStore = DebridCredentialSnapshotStore(initial: a1)
    let splitToken = DebridCredentialRevisionToken(revision: 1, store: splitStore)
    let issuedUsenet = BoolBox()
    let issuedTorrent = BoolBox()
    results.expect(splitToken.authorizeAndIssue({ issuedUsenet.setTrue() }) && issuedUsenet.current,
                   "TorBox usenet task independently resumes while A is current")
    results.expect(splitStore.publish(b2), "TorBox B can publish between the two independent sends")
    results.expect(!splitToken.authorizeAndIssue({ issuedTorrent.setTrue() }) && !issuedTorrent.current,
                   "TorBox torrent task independently rejects A after B")

    let stateStore = DebridCredentialSnapshotStore(initial: a1)
    let state = TorBoxContributorProbe(credentialStore: stateStore)
    let content = "tt0000001|-1|-1"
    results.expect(stateStore.compareAndPublish(revision: 1) {
        state.inFlightKey = content
        state.inFlightRevision = 1
        state.cache[content] = ["visible-a"]
        state.cooldown = true
        state.shownKey = content
        state.publishedContentID = "tt0000001"
        state.visible = ["visible-a"]
    }, "TorBox A pre-send in-flight and visible mutations use the current revision seam")
    results.expect(stateStore.publish(b2), "TorBox B wins after A marks the title in flight")
    results.expect(state.credentialRevision == 2
                   && state.inFlightKey == nil && state.inFlightRevision == nil
                   && state.cache.isEmpty && !state.cooldown
                   && state.shownKey == nil && state.publishedContentID == nil
                   && state.visible.isEmpty,
                   "TorBox B publication synchronously clears A state before publish returns")

    let staleCompletionApplied = stateStore.compareAndPublish(revision: 1) {
        state.inFlightKey = nil
        state.inFlightRevision = nil
        state.cache[content] = ["stale-a"]
        state.cooldown = true
        state.shownKey = "stale-a"
        state.publishedContentID = "stale-a"
        state.visible = ["stale-a"]
    }
    results.expect(!staleCompletionApplied
                   && state.inFlightKey == nil
                   && state.cache.isEmpty
                   && !state.cooldown
                   && state.visible.isEmpty,
                   "stale A completion mutates no in-flight, cache, cooldown, or visible state")

    results.expect(stateStore.compareAndPublish(revision: 2) {
        state.inFlightKey = content
        state.inFlightRevision = 2
        state.shownKey = content
        state.publishedContentID = "tt0000001"
    } && state.inFlightRevision == 2,
                   "same-title B refresh is not stranded behind A in-flight state")
    results.expect(stateStore.compareAndPublish(revision: 2) {
        state.inFlightKey = nil
        state.inFlightRevision = nil
        state.cache[content] = ["b"]
        state.cooldown = true
        state.visible = ["b"]
    }, "current B completion may atomically publish all contributor state")

    let removed3 = snapshot(ownerB, 3, [:])
    let removedPublished = stateStore.publish(removed3)
    results.expect(removedPublished && state.credentialRevision == 3
                   && state.cache.isEmpty && !state.cooldown && state.visible.isEmpty,
                   "TorBox key removal synchronously clears B cache, cooldown, in-flight, and visible state")

    let readded4 = snapshot(ownerB, 4, [.torBox: "b2"])
    let readdedPublished = stateStore.publish(readded4)
    results.expect(readdedPublished && state.credentialRevision == 4,
                   "TorBox key re-add synchronously starts from a clean credential generation")
    _ = stateStore.compareAndPublish(revision: 4) {
        state.cache[content] = ["readded"]
        state.cooldown = true
        state.shownKey = content
        state.publishedContentID = "tt0000001"
        state.visible = ["readded"]
    }
    let unrelated5 = snapshot(ownerB, 5, [.torBox: "b2", .realDebrid: "changed"])
    let unrelatedPublished = stateStore.publish(unrelated5)
    results.expect(unrelatedPublished && state.credentialRevision == 5
                   && state.cache.isEmpty && !state.cooldown
                   && state.shownKey == nil && state.publishedContentID == nil && state.visible.isEmpty,
                   "an unrelated-service revision synchronously invalidates TorBox-derived state")
}

@MainActor
private func testSyncPayloadActualIssuanceFence(_ results: inout Results) {
    let a1 = snapshot(ownerA, 1, [.realDebrid: "a", .torBox: "a-tb"])
    let b2 = snapshot(ownerB, 2, [.realDebrid: "b"])
    let store = DebridCredentialSnapshotStore(initial: a1)
    // Models mergeLocalIntoDoc completing its encrypted payload from A before later token/account awaits.
    let payloadRevision = store.load().revision
    let payloadToken = DebridCredentialRevisionToken(revision: payloadRevision, store: store)
    let reachedTaskResume = DispatchSemaphore(value: 0)
    let allowTaskResume = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let issued = BoolBox()
    let accepted = BoolBox()
    DispatchQueue(label: "vortx.debrid.sync-payload-resume").async {
        reachedTaskResume.signal()
        allowTaskResume.wait()
        if payloadToken.authorizeAndIssue({ issued.setTrue() }) { accepted.setTrue() }
        done.signal()
    }
    reachedTaskResume.wait()
    results.expect(store.publish(b2),
                   "sync credential revision changes after payload construction and before task resume")
    allowTaskResume.signal()
    done.wait()
    results.expect(!accepted.current && !issued.current,
                   "stale encrypted credential payload never issues its URLSession task")
}

@MainActor
private func testNestedRevisionPinSchedules(_ results: inout Results) {
    func staleChild(_ label: String, results: inout Results) {
        let a1 = snapshot(ownerA, 1, [.realDebrid: "a", .torBox: "a-tb"])
        let b2 = snapshot(ownerB, 2, [.realDebrid: "b", .torBox: "b-tb"])
        let store = DebridCredentialSnapshotStore(initial: a1)
        let entryRevision = store.load().revision
        // This is the exact production child-entry seam used by every generation-pinned nested coordinator path.
        let child = DebridCredentialPinnedChildEntry(revision: entryRevision, store: store)
        let issued = BoolBox()
        results.expect(store.publish(b2), "\(label) publishes B before nested child entry")
        let entry = child.enter()
        var accepted = false
        if let token = entry.value {
            accepted = token.authorizeAndIssue { issued.setTrue() }
        }
        results.expect(!issued.current && !accepted && entry.value == nil && entry.revision == entryRevision,
                       "\(label) seam issues zero providers and returns only A's revision")
    }

    staleChild("torrent playback", results: &results)
    staleChild("usenet playback", results: &results)
    staleChild("singleton cached race", results: &results)
    staleChild("fanout cached race", results: &results)
    staleChild("Continue Watching reresolve", results: &results)
    staleChild("torrent cache-awareness child", results: &results)
    staleChild("usenet cache-awareness child", results: &results)
}

@MainActor
private func testCacheAwarenessRevisionReset(_ results: inout Results) {
    let a1 = snapshot(ownerA, 1, [.torBox: "a"])
    let b2 = snapshot(ownerB, 2, [.torBox: "b"])
    let store = DebridCredentialSnapshotStore(initial: a1)
    let state = CacheAwarenessProbe(credentialStore: store)
    let hashes: Set<String> = ["same-hash"]
    let urls: Set<String> = ["same-nzb"]

    results.expect(state.adopt(1, store: store), "cache awareness adopts A revision")
    results.expect(store.compareAndPublish(revision: 1) {
        state.lastHashes = hashes
        state.lastUsenet = urls
        state.cachedHashes = hashes
        state.cachedUsenet = urls
    }, "cache awareness may publish A badges and dedupe sets while A is current")

    let notificationObserved = BoolBox()
    let observer = NotificationCenter.default.addObserver(
        forName: DebridCredentialSnapshotStore.didPublishNotification,
        object: store,
        queue: nil
    ) { _ in
        if store.load().revision == 2 { notificationObserved.setTrue() }
    }
    results.expect(store.publish(b2) && notificationObserved.current,
                   "B publication emits a post-lock signal whose observer can re-enter snapshot reads")
    NotificationCenter.default.removeObserver(observer)

    results.expect(state.credentialRevision == 2
                   && state.lastHashes.isEmpty && state.lastUsenet.isEmpty
                   && state.cachedHashes.isEmpty && state.cachedUsenet.isEmpty,
                   "B revision synchronously clears A cache-awareness state before publish returns")
    var sameInputMayStart = false
    _ = store.compareAndPublish(revision: 2) {
        sameInputMayStart = hashes != state.lastHashes && urls != state.lastUsenet
    }
    results.expect(sameInputMayStart,
                   "same-input refresh under B is not suppressed by A's completed dedupe sets")

    let staleARepublished = store.compareAndPublish(revision: 1) {
        state.lastHashes = hashes
        state.cachedHashes = hashes
    }
    results.expect(!staleARepublished && state.cachedHashes.isEmpty,
                   "late A completion cannot restore badges after B invalidation")
}

private func testBootstrapAndEnvelopeCommit(_ results: inout Results) {
    do {
        let namespace = ownerA.storageNamespace
        let envelopeRaw = #"{"format":1,"generation":7,"keys":{"realDebrid":"old"},"ownerNamespace":"\#(namespace)"}"#
        let markerRaw = #"{"format":1,"generation":7,"ownerNamespace":"\#(namespace)","slot":"a"}"#
        let envelope = DebridCredentialPersistence.decodeCanonical(
            DebridCredentialPersistedEnvelope.self, from: envelopeRaw
        )
        let marker = DebridCredentialPersistence.decodeCanonical(
            DebridCredentialCommitMarker.self, from: markerRaw
        )
        results.expect(envelope?.recoveryPhase == nil && marker?.recoveryPhase == nil,
                       "pre-recovery-field canonical v3 artifacts remain readable")
        results.expect(envelope.flatMap(DebridCredentialPersistence.encodeCanonical) == envelopeRaw
                       && marker.flatMap(DebridCredentialPersistence.encodeCanonical) == markerRaw,
                       "pre-recovery-field v3 artifacts preserve their canonical encoding")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[DebridService.realDebrid.keychainAccount(owner: .signedOutDevice)] = "device-rd"
        let boot = DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: storage.read)
        results.expect(boot.owner == .signedOutDevice && boot.revision == 1,
                       "cold bootstrap synchronously selects the signed-out owner")
        results.expect(boot.keys == [.realDebrid: "device-rd"],
                       "cold bootstrap reads signed-out durable data before DebridKeys initialization")

        results.expect(commit(storage, owner: .signedOutDevice, keys: [:]).succeeded,
                       "an explicit empty signed-out envelope commits")
        let afterClear = DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: storage.read)
        results.expect(afterClear.keys.isEmpty,
                       "committed empty envelope prevents stale local fallback resurrection")
    }

    do {
        let storage = MemoryCredentialStorage()
        let all: [DebridService: String] = [
            .realDebrid: "rd", .allDebrid: "ad", .premiumize: "pm", .torBox: "tb",
        ]
        let result = commit(storage, owner: ownerA, keys: all)
        results.expect(result.succeeded, "one all-service envelope commits")
        results.expect(committedKeys(storage, owner: ownerA) == all,
                       "exact committed envelope reads back as one generation")
        results.expect(committedKeys(storage, owner: ownerB).isEmpty,
                       "another owner cannot read A's envelope")
    }
}

private func testActiveSlotSelectionSurvivesTransientRead(_ results: inout Results) {
    let storage = MemoryCredentialStorage()
    let old: [DebridService: String] = [.realDebrid: "old"]
    let fresh: [DebridService: String] = [.realDebrid: "fresh", .torBox: "fresh-tb"]
    results.expect(commit(storage, owner: ownerA, keys: old).succeeded,
                   "active-slot transient fixture commits generation one in slot A")
    let accounts = DebridCredentialStorageAccounts(owner: ownerA)
    let activeEnvelope = storage.values[accounts.envelopeA]
    let activeMarker = storage.values[accounts.markerA]

    storage.resetReadSchedule()
    // The first load consumes two guard reads plus two marker/envelope pairs. Read seven is where the removed
    // rediscovery would have re-read active marker A; the corrected path reads only inactive marker B there.
    storage.failReadCalls = [7]
    results.expect(commit(storage, owner: ownerA, keys: fresh).succeeded,
                   "one-shot failure at the removed slot-rediscovery schedule cannot redirect the write")
    results.expect(storage.values[accounts.envelopeA] == activeEnvelope
                   && storage.values[accounts.markerA] == activeMarker,
                   "the retained winning slot prevents active envelope or marker overwrite")
    storage.values.removeValue(forKey: accounts.markerB)
    storage.values.removeValue(forKey: accounts.envelopeB)
    results.expect(committedKeys(storage, owner: ownerA) == old,
                   "prior committed keys survive loss of the newly written inactive slot")
}

private enum FirstV3MarkerFailure: CaseIterable {
    case writeRejected
    case corruptReadback

    var label: String {
        switch self {
        case .writeRejected: return "rejected marker write"
        case .corruptReadback: return "partial or corrupt marker readback"
        }
    }
}

private func testFirstV3MarkerFailureRecovery(_ results: inout Results) {
    let authoritative: [DebridService: String] = [.realDebrid: "fresh", .torBox: "fresh-tb"]
    let legacyAccount = DebridService.realDebrid.keychainAccount(owner: ownerA)
    let accounts = DebridCredentialStorageAccounts(owner: ownerA)

    for failure in FirstV3MarkerFailure.allCases {
        let storage = MemoryCredentialStorage()
        storage.values[legacyAccount] = "legacy-must-not-revive"
        switch failure {
        case .writeRejected:
            storage.failWrites.insert(accounts.markerA)
        case .corruptReadback:
            storage.corruptWrites.insert(accounts.markerA)
        }

        results.expect(!commit(storage, owner: ownerA, keys: authoritative).succeeded,
                       "literal first-v3 \(failure.label) is surfaced")
        if case .quarantined = DebridCredentialPersistence.load(owner: ownerA, read: storage.read) {
            results.expect(true, "literal first-v3 \(failure.label) relaunch is quarantined")
        } else {
            results.expect(false, "literal first-v3 \(failure.label) relaunch is quarantined")
        }
        results.expect(DebridCredentialPersistence.loadKeys(owner: ownerA, read: storage.read).isEmpty,
                       "literal first-v3 \(failure.label) cannot revive the legacy key")
        results.expect(!commit(storage, owner: ownerA, keys: [:]).succeeded,
                       "literal first-v3 \(failure.label) rejects an authority-free empty repair")

        storage.failWrites.removeAll()
        storage.corruptWrites.removeAll()
        results.expect(commit(storage, owner: ownerA, keys: authoritative).succeeded,
                       "authoritative retry repairs literal first-v3 \(failure.label)")
        results.expect(committedKeys(storage, owner: ownerA) == authoritative,
                       "repaired literal first-v3 \(failure.label) exposes only fresh keys")
    }
}

private enum RecoveryFailurePosition: CaseIterable {
    case afterGuard
    case afterTargetMarkerDelete
    case afterFreshEnvelopeWrite
    case afterFreshMarkerWrite
    case atStaleMarkerDelete
    case atStaleEnvelopeDelete
    case beforeGuardDelete
    case atFinalMarkerWrite
    case atFinalMarkerReadback

    var label: String {
        switch self {
        case .afterGuard: return "after guard"
        case .afterTargetMarkerDelete: return "after target marker delete"
        case .afterFreshEnvelopeWrite: return "after fresh envelope write"
        case .afterFreshMarkerWrite: return "after fresh marker write"
        case .atStaleMarkerDelete: return "at stale marker delete"
        case .atStaleEnvelopeDelete: return "at stale envelope delete"
        case .beforeGuardDelete: return "before guard delete"
        case .atFinalMarkerWrite: return "at final marker write"
        case .atFinalMarkerReadback: return "at final marker readback"
        }
    }
}

private func quarantinedRecoveryStorage() -> MemoryCredentialStorage {
    let storage = MemoryCredentialStorage()
    let accounts = DebridCredentialStorageAccounts(owner: ownerA)
    storage.values[accounts.markerA] = "corrupt-a"
    storage.values[accounts.envelopeA] = "partial-a"
    storage.values[accounts.markerB] = "corrupt-b"
    storage.values[accounts.envelopeB] = "partial-b"
    storage.values[DebridService.realDebrid.keychainAccount(owner: ownerA)] = "legacy-must-not-revive"
    return storage
}

private func testQuarantinedFreshRecovery(_ results: inout Results) {
    let authoritative: [DebridService: String] = [.realDebrid: "fresh", .torBox: "fresh-tb"]
    let accounts = DebridCredentialStorageAccounts(owner: ownerA)

    for position in RecoveryFailurePosition.allCases {
        let storage = quarantinedRecoveryStorage()
        switch position {
        case .afterGuard:
            storage.failDeletes.insert(accounts.markerA)
        case .afterTargetMarkerDelete:
            storage.failWrites.insert(accounts.envelopeA)
        case .afterFreshEnvelopeWrite:
            storage.corruptWrites.insert(accounts.envelopeA)
        case .afterFreshMarkerWrite:
            storage.corruptWrites.insert(accounts.markerA)
        case .atStaleMarkerDelete:
            storage.failDeletes.insert(accounts.markerB)
        case .atStaleEnvelopeDelete:
            storage.failDeletes.insert(accounts.envelopeB)
        case .beforeGuardDelete:
            storage.failDeletes.insert(accounts.recoveryGuard)
        case .atFinalMarkerWrite:
            storage.failWriteCalls = [5]
        case .atFinalMarkerReadback:
            storage.corruptWriteCalls = [5]
        }

        let first = commit(storage, owner: ownerA, keys: authoritative)
        results.expect(!first.succeeded, "recovery \(position.label) failure is surfaced")
        storage.resetReadSchedule()
        storage.failReadCalls = [1]
        if case .quarantined = DebridCredentialPersistence.load(owner: ownerA, read: storage.read) {
            results.expect(true, "relaunch \(position.label) survives first guard-read miss")
        } else {
            results.expect(false, "relaunch \(position.label) survives first guard-read miss")
        }
        storage.resetReadSchedule()
        storage.failReadCalls = [2]
        results.expect(DebridCredentialPersistence.loadKeys(owner: ownerA, read: storage.read).isEmpty,
                       "relaunch \(position.label) second guard-read miss exposes no credentials or fallback")

        storage.failWrites.removeAll()
        storage.corruptWrites.removeAll()
        storage.failWriteCalls.removeAll()
        storage.corruptWriteCalls.removeAll()
        storage.failDeletes.removeAll()
        results.expect(commit(storage, owner: ownerA, keys: authoritative).succeeded,
                       "authoritative retry repairs \(position.label) interruption")
        results.expect(committedKeys(storage, owner: ownerA) == authoritative,
                       "repaired \(position.label) exposes exactly the fresh candidate")
        results.expect(storage.values[accounts.recoveryGuard] == nil,
                       "repaired \(position.label) clears the durable recovery guard")
    }

    do {
        let storage = preparedTwoGenerationStorage()
        let staged = DebridCredentialPersistedEnvelope(
            generation: 1,
            owner: ownerA,
            keys: authoritative,
            recoveryPhase: .staging
        )
        let stagedMarker = DebridCredentialCommitMarker(
            generation: 1,
            owner: ownerA,
            slot: .a,
            recoveryPhase: .staging
        )
        storage.values[accounts.envelopeA] = DebridCredentialPersistence.encodeCanonical(staged)!
        storage.values[accounts.markerA] = DebridCredentialPersistence.encodeCanonical(stagedMarker)!
        storage.values[accounts.recoveryGuard] = DebridCredentialPersistence.encodeCanonical(
            DebridCredentialRecoveryGuard(owner: ownerA)
        )!
        storage.resetReadSchedule()
        storage.failReadCalls = [1, 2]
        if case .quarantined = DebridCredentialPersistence.load(owner: ownerA, read: storage.read) {
            results.expect(true,
                           "staged pair quarantines when both guard reads miss beside an older valid candidate")
        } else {
            results.expect(false,
                           "staged pair quarantines when both guard reads miss beside an older valid candidate")
        }
        storage.resetReadSchedule()
        storage.failReadCalls = [1, 2]
        results.expect(DebridCredentialPersistence.loadKeys(owner: ownerA, read: storage.read).isEmpty,
                       "staged recovery never exposes fresh, old, or legacy credentials before cleanup")
    }

    do {
        let storage = MemoryCredentialStorage()
        results.expect(commit(storage, owner: ownerA, keys: authoritative).succeeded,
                       "leftover-guard fixture has one fully valid fresh candidate")
        storage.values[accounts.recoveryGuard] = DebridCredentialPersistence.encodeCanonical(
            DebridCredentialRecoveryGuard(owner: ownerA)
        )!
        storage.resetReadSchedule()
        storage.failReadCalls = [1]
        if case .quarantined = DebridCredentialPersistence.load(owner: ownerA, read: storage.read) {
            results.expect(true,
                           "valid fresh candidate plus leftover guard stays closed on first guard-read miss")
        } else {
            results.expect(false,
                           "valid fresh candidate plus leftover guard stays closed on first guard-read miss")
        }
        storage.resetReadSchedule()
        storage.failReadCalls = [2]
        results.expect(DebridCredentialPersistence.loadKeys(owner: ownerA, read: storage.read).isEmpty,
                       "valid fresh candidate plus leftover guard stays closed on second guard-read miss")
    }
}

private enum RemoteFailurePosition: CaseIterable {
    case inactiveMarkerDelete
    case envelopeWrite
    case envelopeReadback
    case markerWrite
    case markerReadback

    var label: String {
        switch self {
        case .inactiveMarkerDelete: return "inactive marker delete"
        case .envelopeWrite: return "envelope write"
        case .envelopeReadback: return "envelope readback"
        case .markerWrite: return "commit marker write"
        case .markerReadback: return "commit marker readback"
        }
    }
}

private func preparedTwoGenerationStorage() -> MemoryCredentialStorage {
    let storage = MemoryCredentialStorage()
    _ = commit(storage, owner: ownerA, keys: [.realDebrid: "old-1"])
    _ = commit(storage, owner: ownerA, keys: [.realDebrid: "old-2", .allDebrid: "old-ad"])
    return storage
}

private func testRemoteFailurePositions(_ results: inout Results) {
    let prior: [DebridService: String] = [.realDebrid: "old-2", .allDebrid: "old-ad"]
    let remote: [DebridService: String] = [
        .realDebrid: "new-rd", .allDebrid: "new-ad", .premiumize: "new-pm", .torBox: "new-tb",
    ]
    let accounts = DebridCredentialStorageAccounts(owner: ownerA)

    for position in RemoteFailurePosition.allCases {
        let storage = preparedTwoGenerationStorage()
        switch position {
        case .inactiveMarkerDelete:
            storage.failDeletes.insert(accounts.markerA)
        case .envelopeWrite:
            storage.failWrites.insert(accounts.envelopeA)
        case .envelopeReadback:
            storage.corruptWrites.insert(accounts.envelopeA)
        case .markerWrite:
            storage.failWrites.insert(accounts.markerA)
        case .markerReadback:
            storage.corruptWrites.insert(accounts.markerA)
        }

        var state = DebridCredentialMutableState(owner: ownerA, keys: prior)
        let before = state.snapshot
        let outcome = DebridCredentialDurableMutation.applyRemoteKeys(
            remote,
            state: &state,
            persist: { commit(storage, owner: ownerA, keys: $0).succeeded }
        )
        results.expect(outcome == .persistenceFailed,
                       "remote \(position.label) failure is surfaced")
        results.expect(state.snapshot == before,
                       "remote \(position.label) failure publishes no in-memory generation")
        results.expect(committedKeys(storage, owner: ownerA) == prior,
                       "remote \(position.label) failure retains the prior durable generation")
        let durable = committedKeys(storage, owner: ownerA)
        results.expect(durable != remote && durable.keys.allSatisfy { prior[$0] == durable[$0] },
                       "remote \(position.label) failure cannot expose a mixed generation")
    }
}

private func testCrashRecovery(_ results: inout Results) {
    let storage = MemoryCredentialStorage()
    let old: [DebridService: String] = [.realDebrid: "old", .allDebrid: "old-ad"]
    let next: [DebridService: String] = [
        .realDebrid: "new", .allDebrid: "new-ad", .premiumize: "new-pm", .torBox: "new-tb",
    ]
    _ = commit(storage, owner: ownerA, keys: old)
    let accounts = DebridCredentialStorageAccounts(owner: ownerA)
    let candidate = DebridCredentialPersistedEnvelope(generation: 2, owner: ownerA, keys: next)
    let candidateRaw = DebridCredentialPersistence.encodeCanonical(candidate)!

    storage.values[accounts.envelopeB] = candidateRaw
    results.expect(committedKeys(storage, owner: ownerA) == old,
                   "crash before commit marker recovers the prior complete generation")

    let marker = DebridCredentialCommitMarker(generation: 2, owner: ownerA, slot: .b)
    storage.values[accounts.markerB] = DebridCredentialPersistence.encodeCanonical(marker)!
    results.expect(committedKeys(storage, owner: ownerA) == next,
                   "crash after commit marker recovers the new complete generation")

    storage.values[accounts.markerB] = "corrupt"
    results.expect(committedKeys(storage, owner: ownerA) == old,
                   "corrupt newest marker quarantines it and recovers the prior marked generation")
}

private func testLocalDurableMutation(_ results: inout Results) {
    var state = DebridCredentialMutableState(owner: ownerA, keys: [.realDebrid: "old"])
    let before = state.snapshot
    let replacement = DebridCredentialDurableMutation.setKey(
        "new", for: .realDebrid, state: &state, persist: { _ in false }
    )
    results.expect(replacement == .persistenceFailed && state.snapshot == before,
                   "failed local replacement leaves published state on the durable old key")

    let clear = DebridCredentialDurableMutation.setKey(
        "", for: .realDebrid, state: &state, persist: { _ in false }
    )
    results.expect(clear == .persistenceFailed && state.snapshot == before,
                   "failed local clear cannot publish revocation while the durable old key survives")

    let storage = MemoryCredentialStorage()
    _ = commit(storage, owner: ownerA, keys: before.keys)
    let success = DebridCredentialDurableMutation.setKey(
        "new",
        for: .realDebrid,
        state: &state,
        persist: { commit(storage, owner: ownerA, keys: $0).succeeded }
    )
    results.expect(success == .committed(state.snapshot),
                   "successful local replacement publishes only after durable commit")
    results.expect(state.keys == [.realDebrid: "new"]
                   && committedKeys(storage, owner: ownerA) == state.keys,
                   "published local state exactly matches durable state")
}

private func testMigrationOwnership(_ results: inout Results) {
    let service = DebridService.realDebrid
    let global = service.legacyGlobalKeychainAccount
    let claim = DebridCredentialMigration.globalClaimAccount(for: service)

    do {
        let storage = MemoryCredentialStorage()
        storage.values[global] = "one-owner"
        storage.failDeletes.insert(global)
        results.expect(migrate(storage, owner: ownerA, service: service, source: global, claim: claim)
                       == .deleteFailed,
                       "delete failure occurs before any global target write")
        results.expect(storage.values[global] == "one-owner"
                       && committedKeys(storage, owner: ownerA).isEmpty,
                       "delete failure leaves only the source credential")

        results.expect(migrate(storage, owner: ownerB, service: service, source: global, claim: claim)
                       == .claimedByOtherOwner,
                       "relaunch under B cannot reassign A's durable global claim")
        results.expect(committedKeys(storage, owner: ownerB).isEmpty,
                       "B receives no copy after A's delete failure")

        storage.failDeletes.remove(global)
        results.expect(migrate(storage, owner: ownerA, service: service, source: global, claim: claim)
                       == .migrated,
                       "relaunch under claimed owner A idempotently repairs the migration")
        results.expect(storage.values[global] == nil
                       && committedKeys(storage, owner: ownerA)[service] == "one-owner",
                       "repaired global credential exists in only A's target")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[global] = "lost-on-crash"
        let accounts = DebridCredentialStorageAccounts(owner: ownerA)
        storage.failWrites.insert(accounts.envelopeA)
        results.expect(migrate(storage, owner: ownerA, service: service, source: global, claim: claim)
                       == .targetWriteFailedAfterSourceDeletion,
                       "target failure after source deletion reports clean loss")
        results.expect(storage.values[global] == nil && committedKeys(storage, owner: ownerA).isEmpty,
                       "mid-migration crash/failure leaves no duplicate target")
        results.expect(migrate(storage, owner: ownerB, service: service, source: global, claim: claim)
                       == .claimedByOtherOwner,
                       "lost claimed credential is never reassigned to B after relaunch")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[global] = "same"
        _ = commit(storage, owner: ownerA, keys: [service: "same"])
        storage.failDeletes.insert(global)
        results.expect(migrate(storage, owner: ownerA, service: service, source: global, claim: claim)
                       == .duplicateTargetRolledBack,
                       "equal target is rolled back when global source deletion fails")
        results.expect(storage.values[global] == "same" && committedKeys(storage, owner: ownerA)[service] == nil,
                       "delete-failed equal credential remains in at most one scope")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[global] = "global-conflict"
        _ = commit(storage, owner: ownerA, keys: [service: "target-wins"])
        results.expect(migrate(storage, owner: ownerA, service: service, source: global, claim: claim)
                       == .targetPresentSourceRemoved,
                       "conflicting target wins while global source is retired")
        results.expect(committedKeys(storage, owner: ownerA)[service] == "target-wins"
                       && storage.values[global] == nil,
                       "conflict repair publishes no mixed or reassigned credential")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[global] = "unclaimed"
        storage.failWrites.insert(claim)
        results.expect(migrate(storage, owner: ownerA, service: service, source: global, claim: claim)
                       == .claimWriteFailed,
                       "claim persistence failure aborts before source deletion")
        results.expect(storage.values[global] == "unclaimed"
                       && committedKeys(storage, owner: ownerA).isEmpty,
                       "failed claim cannot create a target")
    }

    do {
        let storage = MemoryCredentialStorage()
        let rawA = service.legacyRawAccountKeychainAccount(accountA)
        let rawB = service.legacyRawAccountKeychainAccount(accountB)
        storage.values[rawA] = "raw-a"
        storage.values[rawB] = "raw-b"
        results.expect(migrate(storage, owner: ownerA, service: service, source: rawA, claim: nil)
                       == .migrated,
                       "account A raw scope migrates delete-source-first")
        results.expect(migrate(storage, owner: ownerB, service: service, source: rawB, claim: nil)
                       == .migrated,
                       "account B raw scope also migrates in one process")
        results.expect(committedKeys(storage, owner: ownerA)[service] == "raw-a"
                       && committedKeys(storage, owner: ownerB)[service] == "raw-b",
                       "raw account migrations preserve owner isolation")
    }

    do {
        let storage = MemoryCredentialStorage()
        let noncanonical = accountAString.uppercased()
        let rawNoncanonical = "vortx.debrid.realDebrid." + noncanonical
        storage.values[rawNoncanonical] = "must-stay"
        results.expect(DebridOwnerScope.canonicalAccount(noncanonical) == nil,
                       "noncanonical raw owner is not eligible for migration")
        results.expect(storage.values[rawNoncanonical] == "must-stay",
                       "noncanonical raw source remains intact")
    }
}

@MainActor
private func testConcurrentReads(_ results: inout Results) {
    let initial = snapshot(.signedOutDevice, 1)
    let store = DebridCredentialSnapshotStore(initial: initial)
    let failures = FailureBox()
    let workerCount = 8
    let ready = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let readersDone = DispatchGroup()
    for _ in 0..<workerCount {
        readersDone.enter()
        DispatchQueue.global().async {
            ready.signal()
            start.wait()
            for _ in 0..<2_500 {
                let current = store.load()
                if current.revision == 1 {
                    if current.owner != .signedOutDevice || !current.keys.isEmpty {
                        failures.append("initial envelope was torn")
                    }
                } else {
                    let expectedService: DebridService = current.revision.isMultiple(of: 2) ? .torBox : .realDebrid
                    if current.owner != ownerA || current.keys != [expectedService: String(current.revision)] {
                        failures.append("published envelope was torn")
                    }
                }
                _ = store.isConfigured(.torBox)
                _ = store.isCurrent(revision: current.revision)
            }
            readersDone.leave()
        }
    }
    for _ in 0..<workerCount { ready.wait() }
    for _ in 0..<workerCount { start.signal() }
    for revision in UInt64(2)...UInt64(2_000) {
        let service: DebridService = revision.isMultiple(of: 2) ? .torBox : .realDebrid
        _ = store.publish(snapshot(ownerA, revision, [service: String(revision)]))
    }
    readersDone.wait()
    results.expect(failures.isEmpty,
                   "concurrent detached reads observe only complete immutable snapshots")
    results.expect(store.load().revision == 2_000,
                   "concurrent publication converges on the final revision")
}

@main
@MainActor
private enum DebridCredentialOrderingTestRunner {
    static func main() async {
        var results = Results()
        testOwnerGrammar(&results)
        testRevisionOrdering(&results)
        testMutableState(&results)
        testRequestAndPublicationFences(&results)
        await testTorBoxTwoLegAndStateSchedules(&results)
        testSyncPayloadActualIssuanceFence(&results)
        testNestedRevisionPinSchedules(&results)
        testCacheAwarenessRevisionReset(&results)
        testBootstrapAndEnvelopeCommit(&results)
        testActiveSlotSelectionSurvivesTransientRead(&results)
        testFirstV3MarkerFailureRecovery(&results)
        testQuarantinedFreshRecovery(&results)
        testRemoteFailurePositions(&results)
        testCrashRecovery(&results)
        testLocalDurableMutation(&results)
        testMigrationOwnership(&results)
        testConcurrentReads(&results)

        if results.failed.isEmpty {
            print("ALL PASS (\(results.passed) checks)")
        } else {
            print("FAILED \(results.failed.count) of \(results.passed + results.failed.count) checks")
            for failure in results.failed { print(" - \(failure)") }
            exit(1)
        }
    }
}
