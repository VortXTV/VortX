import Foundation
import CryptoKit

/// The real encrypted draft store, journal, producer and decoder. All keys and data are
/// synthetic; the owning runner retains this isolated receipt directory under app/build.
enum VortxNativeWatchedStreamTests {
    typealias T = VortxNativeWatchedArchiveTests
    enum SimulatedCrash: Error { case afterDurableWrite }
    struct Authority: VortxMutationAuthority {
        func withActive(_ operation: () throws -> Void) throws { try operation() }
    }
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        func isCurrent() -> Bool { lock.withLock { active } }
        func revoke() { lock.withLock { active = false } }
    }
    actor Counter {
        private var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }
    actor BoundaryGate {
        enum Failure: Error { case operationFinishedBeforeCheckpoint, watchdogExpired }
        private let stop: Int
        private var visits = 0
        private var parked = false
        private var failure: (any Error)?
        private var waiters: [CheckedContinuation<Void, any Error>] = []
        private var releaseWaiter: CheckedContinuation<Void, any Error>?
        private var watchdog: Task<Void, Never>?
        init(stop: Int) { self.stop = stop }
        private func startWatchdog() {
            guard watchdog == nil else { return }
            // Test-harness liveness only, not an elapsed-time performance assertion.
            watchdog = Task.detached(priority: .background) { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                await self?.abort(Failure.watchdogExpired)
            }
        }
        private func abort(_ error: any Error) {
            guard failure == nil else { return }
            failure = error
            let ready = waiters; waiters.removeAll()
            ready.forEach { $0.resume(throwing: error) }
            releaseWaiter?.resume(throwing: error); releaseWaiter = nil
        }
        func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
            startWatchdog()
            defer {
                if !parked { abort(Failure.operationFinishedBeforeCheckpoint) }
                watchdog?.cancel(); watchdog = nil
            }
            return try await operation()
        }
        func checkpoint() async throws {
            try Task.checkCancellation()
            if let failure { throw failure }
            visits += 1
            guard visits == stop else { return }
            parked = true
            let ready = waiters; waiters.removeAll()
            ready.forEach { $0.resume() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if let failure { continuation.resume(throwing: failure) }
                    else { releaseWaiter = continuation }
                }
            } onCancel: { Task { await self.abort(CancellationError()) } }
        }
        func waitUntilParked() async throws {
            try Task.checkCancellation()
            if let failure { throw failure }
            if parked { return }
            startWatchdog()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if let failure { continuation.resume(throwing: failure) }
                    else { waiters.append(continuation) }
                }
            } onCancel: { Task { await self.abort(CancellationError()) } }
        }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
        func count() -> Int { visits }
    }
    private static func gateFailureTests() async throws {
        let short = BoundaryGate(stop: 2)
        try await short.run { try await short.checkpoint() }
        do { try await short.waitUntilParked(); preconditionFailure("A completed operation left its gate parked") }
        catch BoundaryGate.Failure.operationFinishedBeforeCheckpoint {}
        let cancelledGate = BoundaryGate(stop: 1)
        let waiter = Task { try await cancelledGate.waitUntilParked() }
        waiter.cancel()
        do { try await waiter.value; preconditionFailure("Cancelled gate wait succeeded") }
        catch is CancellationError {}
    }
    struct LeaseAuthority: VortxMutationAuthority {
        let lease: Lease
        func withActive(_ operation: () throws -> Void) throws {
            guard lease.isCurrent() else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked }
            try operation()
        }
    }
    @MainActor final class MainSentinel { var visits = 0 }
    @MainActor private static func rejectedAsync(_ label: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { return }
        preconditionFailure("Accepted worker negative: \(label)")
    }
    /// No wall-clock threshold. The test owns the park/release handshake; the main actor
    /// must execute the sentinel while real worker admission is suspended between records.
    @MainActor private static func workerIsolationAndConservation(directory: URL, repository: URL) async throws {
        let source = try T.source(bytes: 8_192, count: 4)
        let prepared = try await T.prepare(source)
        let pending = try await T.prepare(source, available: false)
        let originalPending = try pending.pendingArchives
        let empty = try VortxNativeBootstrapArchive.encode(document: T.encode(["future": ["kept": true]]))
        let archive = try VortxNativeWatchedArchive.retaining(empty, evidence: prepared.archives, scope: T.scope)
        let originalArchive = archive
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: T.scope, isCurrent: { true })
        try await worker.assertOffMainExecutorForTest()
        T.check(try await worker.retaining(archive, prior: archive) == archive, "worker retains exact idempotent journal bytes")
        let unresolved = try VortxNativeWatchedArchive.retaining(empty, pending: originalPending, scope: T.scope)
        let merged = try await worker.retaining(archive, prior: unresolved)
        T.check(Set(try VortxNativeWatchedArchive.entries(merged, key: VortxNativeWatchedArchive.pendingKey)) == Set(originalPending),
            "worker retains every original pending byte after completion")
        T.check(try await worker.pendingProfileIDs(merged).isEmpty, "worker pending projection requires validated matching tuples")
        let lookup = try await worker.evidenceLookup(archive)
        let requested = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: T.scope.account, profileID: T.owner, ownerProfileID: T.owner)
        let replayed = try lookup(requested, T.digest(source), .authenticatedOwnerLibrary(index: 0))
        T.check(replayed.count == 1 && prepared.archives.contains(replayed[0]), "worker lookup reconstructs exact immutable receipt")
        let malformed = Data("not-json".utf8)
        // Creating an actor on the main actor must not inspect even malformed archive bytes.
        let cheap = try VortxNativeWatchedArchive.Stream(archive: malformed, scope: T.scope,
            isCurrent: { true })
        try await rejectedAsync("malformed lazy stream") { _ = try await cheap.finish() }
        try await rejectedAsync("wrong account") {
            let foreign = VortxNativeWatchedArchive.RecoveryWorker(
                scope: .init(account: "foreign", ownerProfileID: T.scope.ownerProfileID), isCurrent: { true })
            try await foreign.validate(archive)
        }
        var damagedRoot = try T.object(archive)
        var damagedHost = damagedRoot["hostDocument"] as! T.Object
        damagedHost[VortxNativeWatchedArchive.sourcesKey] = [T.digest(source): Data("different-source".utf8).base64EncodedString()]
        damagedRoot["hostDocument"] = damagedHost
        let damaged = try T.encode(damagedRoot)
        try await rejectedAsync("conflicting pooled digest") { try await worker.validate(damaged) }
        var malformedReceipt = try T.object(prepared.archives[0])
        let badSource = Data("not-a-source-object".utf8)
        malformedReceipt["sourceDocumentBase64"] = badSource.base64EncodedString()
        malformedReceipt["sourceDocumentSha256"] = T.digest(badSource)
        let malformedSourceJournal = try T.encode(["schemaVersion": 1, "excludedCredentialPaths": [],
            "hostDocument": [VortxNativeWatchedArchive.evidenceKey: [try T.encode(malformedReceipt).base64EncodedString()]]])
        try await rejectedAsync("correct digest with malformed source") { try await worker.validate(malformedSourceJournal) }
        let noncanonical = Data(" \n".utf8) + prepared.archives[0] + Data("\n".utf8)
        let legacy = try VortxNativeBootstrapArchive.encode(document: T.encode([
            VortxNativeWatchedArchive.evidenceKey: [noncanonical.base64EncodedString()]]))
        let ambiguous = try await worker.retaining(archive, prior: legacy)
        let ambiguousLookup = try await worker.evidenceLookup(ambiguous)
        try T.rejected("worker exact-tuple ambiguity") { _ = try ambiguousLookup(requested, T.digest(source), .authenticatedOwnerLibrary(index: 0)) }
        let ambiguousPending = try await worker.retaining(ambiguous, prior: unresolved)
        T.check(try await worker.pendingProfileIDs(ambiguousPending) == [T.owner], "ambiguous receipt cannot hide original pending work")
        let conflict = try VortxNativeBootstrapArchive.encode(document: T.encode(["future": ["kept": false]]))
        try await rejectedAsync("conflicting unknown retained field") { _ = try await worker.retaining(conflict, prior: archive) }

        let testDirectory = directory.appendingPathComponent("worker-phase-a", isDirectory: true)
        let store = try VortxEncryptedCheckpointStore(directory: testDirectory,
            key: SymmetricKey(data: Data(repeating: 0x41, count: 32)))
        try store.retainMigrationDraft(archive, scope: T.scope, authority: Authority())
        let filename = "native-migration-draft-v1-" + T.digest(T.scope.authenticatedData) + ".sealed"
        let draftURL = testDirectory.appendingPathComponent(filename)
        let originalCiphertext = try Data(contentsOf: draftURL)
        var changedRoot = try T.object(archive)
        var changedHost = changedRoot["hostDocument"] as! T.Object
        changedHost["futureAdded"] = ["retained": true]
        changedRoot["hostDocument"] = changedHost
        let candidate = try T.encode(changedRoot)
        // One source, four headers and four size preflights put checkpoint 14 between
        // the first and second strict receipt replay. No timer or throughput inference.
        let sentinel = MainSentinel()
        for cancel in [true, false] {
            let lease = Lease(), gate = BoundaryGate(stop: 14)
            let task = Task {
                try await gate.run {
                    try await store.retainMigrationDraftCooperatively(candidate, scope: T.scope, expected: archive,
                        authority: LeaseAuthority(lease: lease), checkpoint: { try await gate.checkpoint() })
                }
            }
            try await gate.waitUntilParked()
            sentinel.visits += 1
            T.check(await gate.count() == 14, "park occurs between bounded replay groups")
            if cancel { task.cancel() } else { lease.revoke() }
            await gate.release()
            do { try await task.value; preconditionFailure("Cancelled or revoked worker installed a draft") }
            catch is CancellationError { T.check(cancel, "only cancellation uses cancellation failure") }
            catch LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked {
                T.check(!cancel, "revocation fails closed with its exact authority error")
            }
            T.check(try Data(contentsOf: draftURL) == originalCiphertext, "cancel/revoke preserves exact durable ciphertext")
            T.check(try store.readMigrationDraft(scope: T.scope) == originalArchive, "cancel/revoke preserves exact plaintext draft")
            T.check(archive == originalArchive, "input original never mutates")
        }
        T.check(sentinel.visits == 2, "main-actor sentinel progresses while each worker is parked")
        // An already-revoked admission never reaches the checkpoint hook or writes.
        let retired = Lease(); retired.revoke()
        let visits = Counter()
        try await rejectedAsync("pre-work revocation") {
            try await store.retainMigrationDraftCooperatively(candidate, scope: T.scope, expected: archive,
                authority: LeaseAuthority(lease: retired), checkpoint: { await visits.increment() })
        }
        let retiredVisits = await visits.value()
        let afterRetirement = try Data(contentsOf: draftURL)
        T.check(retiredVisits == 0 && afterRetirement == originalCiphertext,
            "revoked work stops before traversal and leaves draft untouched")
        let readGate = BoundaryGate(stop: 14)
        let draftReader: any VortxCheckpointStore = store
        let reading = Task {
            try await readGate.run {
                try await draftReader.readMigrationDraftCooperatively(scope: T.scope,
                    isCurrent: { true }, checkpoint: { try await readGate.checkpoint() })
            }
        }
        try await readGate.waitUntilParked()
        // This second reader must complete while cooperative replay is parked: no file
        // lock may survive the suspension. All bytes were snapshotted before that replay.
        T.check(try store.readMigrationDraft(scope: T.scope) == archive, "draft file lock is released before cooperative validation suspends")
        reading.cancel()
        await readGate.release()
        do { _ = try await reading.value; preconditionFailure("Cancelled draft read returned a result") }
        catch is CancellationError {}
        T.check(try Data(contentsOf: draftURL) == originalCiphertext, "cancelled reader leaves exact draft ciphertext intact")
        // New cooperative writes keep strict original expected-byte CAS, including stale ACKs.
        let lostAcknowledgement = VortxNativeWatchedArchive.DraftPublisher(expected: archive) { bytes, expected in
            try await store.retainMigrationDraftCooperatively(bytes, scope: T.scope, expected: expected, authority: Authority())
            throw SimulatedCrash.afterDurableWrite
        }
        do { try await lostAcknowledgement.publish(candidate); preconditionFailure("Missing simulated lost acknowledgement") }
        catch SimulatedCrash.afterDurableWrite {}
        try await rejectedAsync("same publisher cannot advance expected bytes after lost ACK") {
            try await lostAcknowledgement.publish(candidate)
        }
        try await rejectedAsync("stale cooperative CAS") {
            try await store.retainMigrationDraftCooperatively(archive, scope: T.scope, expected: archive, authority: Authority())
        }
        T.check(try await worker.readDraft(store) == candidate, "fresh cooperative reopen reads the exact acknowledged draft")
        T.check(try store.read(scope: T.scope) == nil, "cooperative draft publication cannot create a native checkpoint")

        let watchedSource = try String(contentsOf: repository.appendingPathComponent("app/SourcesShared/VortxNativeWatchedArchive.swift"), encoding: .utf8)
        let streamSection = String(watchedSource.components(separatedBy: "    actor Stream {").last!)
        let initializer = String(streamSection.components(separatedBy: "        init(archive:").last!.components(separatedBy: "        fileprivate func initialize()").first!)
        T.check(!initializer.contains("try validate(") && !initializer.contains("Journal(") && !initializer.contains("journal.expanded"),
            "real synchronous Stream initializer contains no replay or recompaction")
        for file in ["app/SourcesShared/CoreBridge.swift", "app/SourcesShared/VortXSyncManager.swift"] {
            let text = try String(contentsOf: repository.appendingPathComponent(file), encoding: .utf8)
            T.check(text.contains("try await recovery.stream(") && text.contains("try await recovery.evidenceLookup("),
                "both actual main-actor callers await the actor boundary")
            T.check(!text.contains("VortxNativeWatchedArchive.Stream(") && !text.contains("VortxNativeWatchedArchive.evidenceLookup(")
                && !text.contains("VortxNativeWatchedArchive.retaining(") && !text.contains("VortxNativeWatchedArchive.pendingProfileIDs("),
                "actual callers contain no synchronous journal helper escape")
        }
        let sync = try String(contentsOf: repository.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift"), encoding: .utf8)
        T.check(sync.contains("self.nativeWatchedPendingGeneration == generation") && sync.contains("isCurrentSource()"),
            "deferred display projection rejects stale source and older generation results")
    }
    static func count(_ archive: Data, _ key: String) throws -> Int {
        let host = try T.object(archive)["hostDocument"] as! T.Object
        return (host[key] as? [Any])?.count ?? 0
    }
    private static func validationBoundaries(_ archive: Data) async throws -> Int {
        let visits = Counter()
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: T.scope, isCurrent: { true },
            checkpoint: { await visits.increment() })
        try await worker.validate(archive)
        return await visits.value()
    }
    /// Source-bound comparative checks of actual cooperative checkpoint counts, not
    /// elapsed time or a replacement validator. Counts need not detect every control-
    /// flow/placement drift; source review and paired semantic checks remain required.
    @MainActor private static func retrySnapshotTests(directory: URL) async throws {
        let source = try T.source(bytes: 8_192, count: 2)
        let prepared = try await T.prepare(source)
        let unavailable = try await T.prepare(source, available: false)
        let originalPending = try unavailable.pendingArchives
        let noncanonical = Data(" \n".utf8) + originalPending[0] + Data("\n".utf8)
        let allPending = originalPending + [noncanonical]
        let original = try VortxNativeBootstrapArchive.encode(document: T.encode(["sourceFuture": ["kept": true]]))
        let base = try VortxNativeBootstrapArchive.encode(
            document: T.encode(["future": ["kept": NSNull()], "apiKeys": ["provider": "fixture-excluded"]]),
            material: T.encode(["schemaVersion": 1, "sourceClock": 1000.125]), authenticatedSourceArchive: original)
        let pending = Data(" \n".utf8) + (try VortxNativeWatchedArchive.retaining(base, pending: allPending, scope: T.scope))
        let resolved = Data(" \n".utf8) + (try VortxNativeWatchedArchive.retaining(pending, evidence: prepared.archives, scope: T.scope))
        let complete = try VortxNativeWatchedArchive.retaining(base, evidence: prepared.archives, scope: T.scope)
        T.check(prepared.archives.count == 2 && allPending.count == 3, "small retry fixture has two tuples and three immutable observations")
        // A completed tuple retains all pending observations. No-op retry must not
        // instantiate/recompact a write stream or normalize the original envelope.
        for (input, offline) in [(resolved, false), (pending, true), (complete, false)] {
            let strict = try await validationBoundaries(input)
            let evidenceCount = try count(input, VortxNativeWatchedArchive.evidenceKey)
            let pendingCount = try count(input, VortxNativeWatchedArchive.pendingKey)
            let visits = Counter(), fetches = Counter(), writes = Counter()
            let result = try await VortxNativeWatchedArchive.retryHistorical(input, scope: T.scope,
                isCurrent: { true }, fetch: { _ in
                    await fetches.increment()
                    guard offline else { preconditionFailure("Completed retry unexpectedly fetched") }
                    throw URLError(.notConnectedToInternet)
                }, persist: { _ in await writes.increment() }, checkpoint: { await visits.increment() })
            let expected = pendingCount == 0 ? strict + 1 : strict + evidenceCount + pendingCount + 3
            let actual = await visits.value()
            FileHandle.standardError.write(Data("Retry snapshot no-new checkpoints: actual=\(actual) expected=\(expected) strict=\(strict) evidence=\(evidenceCount) pending=\(pendingCount)\n".utf8))
            T.check(actual == expected, "no-new retry uses one full preflight and no stream initialization traversal")
            T.check(result == input, "no-new retry retains exact original envelope spelling")
            T.check(await writes.value() == 0, "no-new retry never publishes or acknowledges a draft")
            T.check(await fetches.value() == (offline ? 2 : 0), "pending spelling variants never duplicate capture")
        }
        let strict = try await validationBoundaries(pending)
        let pendingCount = try count(pending, VortxNativeWatchedArchive.pendingKey)
        let visits = Counter(), fetches = Counter(), writes = Counter()
        let result = try await VortxNativeWatchedArchive.retryHistorical(pending, scope: T.scope,
            isCurrent: { true }, fetch: { request in await fetches.increment(); return try T.metadata(request) },
            persist: { _ in await writes.increment() }, checkpoint: { await visits.increment() })!
        // No original evidence, P original pending records, F fresh receipts: one
        // preflight + P retry groups + P compaction groups + F appends + 8 boundaries.
        let changedActual = await visits.value(), changedExpected = strict + 2 * pendingCount + prepared.archives.count + 8
        FileHandle.standardError.write(Data("Retry snapshot changed checkpoints: actual=\(changedActual) expected=\(changedExpected) strict=\(strict) pending=\(pendingCount) fresh=\(prepared.archives.count)\n".utf8))
        T.check(changedActual == changedExpected,
            "first-new retry initializes once from its snapshot without a second strict replay")
        T.check(await fetches.value() == 2, "lazy retry still validates/captures each missing tuple")
        T.check(await writes.value() == 1, "tiny changed retry flushes exactly once")
        T.check(Set(try VortxNativeWatchedArchive.entries(result, key: VortxNativeWatchedArchive.pendingKey)) == Set(allPending),
            "snapshot path retains canonical and noncanonical pending originals")
        T.check(Set(try VortxNativeWatchedArchive.entries(result, key: VortxNativeWatchedArchive.evidenceKey)) == Set(prepared.archives),
            "new receipts retain exact original source and metadata bytes")
        let beforeEnvelope = try JSONDecoder().decode(VortxJSON.self, from: pending)
        let afterEnvelope = try JSONDecoder().decode(VortxJSON.self, from: result)
        for key in ["legacyImportMaterial", "authenticatedSourceArchive", "excludedCredentialPaths"] {
            T.check(afterEnvelope[key] == beforeEnvelope[key], "snapshot retains outer witness \(key)")
        }
        T.check(afterEnvelope["hostDocument"]?["future"] == beforeEnvelope["hostDocument"]?["future"], "unknown/null host values survive")
        T.check(try VortxNativeWatchedArchive.pendingProfileIDs(result).isEmpty, "only validated matching evidence clears pending display")

        let storeDirectory = directory.appendingPathComponent("retry-snapshot")
        let key = SymmetricKey(data: Data(repeating: 0x63, count: 32))
        let store = try VortxEncryptedCheckpointStore(directory: storeDirectory, key: key)
        try store.retainMigrationDraft(pending, scope: T.scope, authority: Authority())
        let draftURL = storeDirectory.appendingPathComponent("native-migration-draft-v1-" + T.digest(T.scope.authenticatedData) + ".sealed")
        let originalCiphertext = try Data(contentsOf: draftURL)
        // Park first before seed construction, then between seed compaction groups.
        // The existing watchdog is a hang guard only; expected failures stay typed.
        let sentinel = MainSentinel()
        for cancel in [true, false] {
            let lease = Lease(), gate = BoundaryGate(stop: strict + (cancel ? 4 : 6)), publications = Counter()
            let task = Task {
                try await gate.run {
                    try await VortxNativeWatchedArchive.retryHistorical(pending, scope: T.scope,
                        isCurrent: { lease.isCurrent() }, fetch: { try T.metadata($0) }, persist: { bytes in
                            await publications.increment()
                            try store.retainMigrationDraft(bytes, scope: T.scope, expected: pending, authority: LeaseAuthority(lease: lease))
                        }, checkpoint: { try await gate.checkpoint() })
                }
            }
            try await gate.waitUntilParked()
            sentinel.visits += 1
            T.check(try store.readMigrationDraft(scope: T.scope) == pending, "no draft lock spans snapshot handoff/compaction suspension")
            if cancel { task.cancel() } else { lease.revoke() }
            await gate.release()
            do { _ = try await task.value; preconditionFailure("Cancelled or retired snapshot published") }
            catch is CancellationError { T.check(cancel, "snapshot cancellation is typed") }
            catch LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked { T.check(!cancel, "snapshot revocation is typed") }
            T.check(await publications.value() == 0, "retired snapshot never reaches persistence")
            T.check(try Data(contentsOf: draftURL) == originalCiphertext, "snapshot cancellation preserves ciphertext")
        }
        T.check(sentinel.visits == 2, "main actor advances at both snapshot suspension points")
        let staleGate = BoundaryGate(stop: strict + 3)
        let stalePublisher = VortxNativeWatchedArchive.DraftPublisher(expected: pending) { bytes, expected in
            try store.retainMigrationDraft(bytes, scope: T.scope, expected: expected, authority: Authority())
        }
        let stale = Task {
            try await staleGate.run {
                try await VortxNativeWatchedArchive.retryHistorical(pending, scope: T.scope, isCurrent: { true },
                    fetch: { try T.metadata($0) }, persist: { try await stalePublisher.publish($0) },
                    checkpoint: { try await staleGate.checkpoint() })
            }
        }
        try await staleGate.waitUntilParked()
        let winner = pending + Data(" \t\n".utf8)
        try store.retainMigrationDraft(winner, scope: T.scope, expected: pending, authority: Authority())
        let winnerCiphertext = try Data(contentsOf: draftURL)
        await staleGate.release()
        do { _ = try await stale.value; preconditionFailure("Snapshot replaced a concurrent exact-byte winner") }
        catch VortxNativeError.superseded {}
        T.check(try Data(contentsOf: draftURL) == winnerCiphertext, "stale snapshot leaves winning ciphertext unchanged")
        T.check(try store.readMigrationDraft(scope: T.scope) == winner, "stale snapshot leaves winning plaintext unchanged")
        try store.retainMigrationDraft(pending, scope: T.scope, expected: winner, authority: Authority())
        let lost = VortxNativeWatchedArchive.DraftPublisher(expected: pending) { bytes, expected in
            try store.retainMigrationDraft(bytes, scope: T.scope, expected: expected, authority: Authority())
            throw SimulatedCrash.afterDurableWrite
        }
        do { _ = try await VortxNativeWatchedArchive.retryHistorical(pending, scope: T.scope, isCurrent: { true },
                fetch: { try T.metadata($0) }, persist: { try await lost.publish($0) })
            preconditionFailure("Missing snapshot lost-ACK fixture error") }
        catch SimulatedCrash.afterDurableWrite {}
        let lostCiphertext = try Data(contentsOf: draftURL)
        do { _ = try await VortxNativeWatchedArchive.retryHistorical(pending, scope: T.scope, isCurrent: { true },
                fetch: { try T.metadata($0) }, persist: { try await lost.publish($0) })
            preconditionFailure("Snapshot advanced expected bytes after lost ACK") }
        catch VortxNativeError.superseded {}
        T.check(try Data(contentsOf: draftURL) == lostCiphertext, "lost-ACK retry cannot overwrite durable bytes")
        let cold = try VortxEncryptedCheckpointStore(directory: storeDirectory, key: key)
        T.check(try cold.readMigrationDraft(scope: T.scope) == result, "old strict reader reopens the exact snapshot result")
        T.check(try cold.read(scope: T.scope) == nil, "snapshot persistence cannot mount an account")

        var broken = try T.object(pending)
        var brokenHost = broken["hostDocument"] as! T.Object
        brokenHost[VortxNativeWatchedArchive.sourcesKey] = [T.digest(source): Data("different-source".utf8).base64EncodedString()]
        broken["hostDocument"] = brokenHost
        let negatives: [(Data, VortxAccountScope)] = [
            (Data("not-json".utf8), T.scope), (try T.encode(broken), T.scope),
            (Data(#"{"schemaVersion":1,"excludedCredentialPaths":[],"hostDocument":{"authKey":"fixture-not-a-credential"}}"#.utf8), T.scope),
            (pending, .init(account: "foreign", ownerProfileID: T.owner.uuidString)),
            (pending, .init(account: T.scope.account, ownerProfileID: UUID().uuidString))]
        for (bad, scope) in negatives {
            let badFetches = Counter(), badWrites = Counter()
            try await rejectedAsync("invalid retry snapshot") {
                _ = try await VortxNativeWatchedArchive.retryHistorical(bad, scope: scope, isCurrent: { true },
                    fetch: { request in await badFetches.increment(); return try T.metadata(request) },
                    persist: { _ in await badWrites.increment() })
            }
            T.check(await badFetches.value() == 0, "invalid snapshot never invokes metadata provider")
            T.check(await badWrites.value() == 0, "invalid snapshot never publishes")
            let raw = try VortxNativeWatchedArchive.Stream(archive: bad, scope: scope, isCurrent: { true })
            try await rejectedAsync("raw stream still validates independently") { _ = try await raw.finish() }
        }
        // Both raw and seeded initialization enter the same operationActive gate.
        // Only the raw public path exposes its handle before initialization, so it is
        // the externally reachable reentrancy boundary exercised here.
        let reentrantGate = BoundaryGate(stop: 2)
        let raw = try VortxNativeWatchedArchive.Stream(archive: pending, scope: T.scope, isCurrent: { true },
            checkpoint: { try await reentrantGate.checkpoint() })
        let initializing = Task { try await reentrantGate.run { try await raw.finish() } }
        try await reentrantGate.waitUntilParked()
        do { try await raw.append(prepared.archives[0], pending: false); preconditionFailure("Reentrant append entered unfinished maps") }
        catch VortxNativeWatchedArchive.Failure.malformed {}
        do { _ = try await raw.finish(); preconditionFailure("Reentrant finish published unfinished maps") }
        catch VortxNativeWatchedArchive.Failure.malformed {}
        await reentrantGate.release()
        let unchanged = try await initializing.value
        T.check(Set(try VortxNativeWatchedArchive.entries(unchanged, key: VortxNativeWatchedArchive.pendingKey)) == Set(allPending),
            "reentrant rejection preserves original pending map")
        print("Retry snapshot: one-preflight traversal, lazy no-op, exact history, cancellation, stale CAS, lost ACK, cold read and reentrancy passed")
    }
    static func run() async throws {
        precondition(CommandLine.arguments.count == 3)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repository = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        T.check(directory.path.hasPrefix(repository.appendingPathComponent("app/build/").path), "synthetic draft path is in the disposable runner directory")
        try await gateFailureTests()
        try await workerIsolationAndConservation(directory: directory, repository: repository)
        try await retrySnapshotTests(directory: directory)
        let key = SymmetricKey(data: Data(repeating: 0x75, count: 32))
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        let source = try T.source(count: 80)
        let empty = try VortxNativeBootstrapArchive.encode(document: T.encode(["ownAccountSources": T.Object()]))
        let publisher = VortxNativeWatchedArchive.DraftPublisher(expected: nil) { archive, expected in
            try store.retainMigrationDraft(archive, scope: T.scope, expected: expected, authority: Authority())
            throw SimulatedCrash.afterDurableWrite
        }
        let stream = try VortxNativeWatchedArchive.Stream(archive: empty, scope: T.scope,
            isCurrent: { true }, persist: { try await publisher.publish($0) })
        let beforeCrash = Counter()
        do {
            _ = try await VortxLegacyWatchedMigration.prepare(accountID: T.scope.account, ownerProfileID: T.owner,
                document: source, profileIDs: [T.owner], receiptSink: { try await stream.append($0, pending: $1) },
                isCurrent: { true }, fetch: { request in await beforeCrash.increment(); return try T.metadata(request) })
            preconditionFailure("Simulated crash did not interrupt producer")
        } catch SimulatedCrash.afterDurableWrite {}
        T.check(await beforeCrash.value() == 64, "producer stopped at the durable first batch, before fetching row 65")
        let cold = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        let saved = try cold.readMigrationDraft(scope: T.scope)!
        T.check(try count(saved, VortxNativeWatchedArchive.evidenceKey) == 64, "cold reopen recovered all acknowledged-on-disk evidence despite lost publisher ACK")
        T.check(try cold.read(scope: T.scope) == nil, "a migration draft cannot mount or create a native checkpoint")
        let savedHost = try T.object(saved)["hostDocument"] as! T.Object
        T.check(savedHost["nativeWatchedMigrationSources"] as? [String: String] == [T.digest(source): source.base64EncodedString()], "first batch retains the exact entire original source")
        let resumedPublisher = VortxNativeWatchedArchive.DraftPublisher(expected: saved) { archive, expected in
            try cold.retainMigrationDraft(archive, scope: T.scope, expected: expected, authority: Authority())
        }
        let resumed = try VortxNativeWatchedArchive.Stream(archive: saved, scope: T.scope,
            isCurrent: { true }, persist: { try await resumedPublisher.publish($0) })
        let fetched = Counter()
        let prepared = try await VortxLegacyWatchedMigration.prepare(accountID: T.scope.account, ownerProfileID: T.owner,
            document: source, profileIDs: [T.owner], archivedEvidenceLookup: VortxNativeWatchedArchive.evidenceLookup(saved, scope: T.scope),
            receiptSink: { try await resumed.append($0, pending: $1) }, isCurrent: { true },
            fetch: { request in await fetched.increment(); return try T.metadata(request) })
        T.check(prepared.rows.count == 80 && prepared.archives.isEmpty && prepared.unresolved.isEmpty,
                "production preparation returns all authorizing rows without an expanded receipt array")
        T.check(await fetched.value() == 16, "cold restart fetched only rows not sealed before the crash")
        let finished = try await resumed.finish()
        T.check(try count(finished, VortxNativeWatchedArchive.evidenceKey) == 80 && finished.count < 2 * 1_024 * 1_024,
                "80 one-MiB-source receipts fit the unchanged compact storage policy")
        T.check(try cold.readMigrationDraft(scope: T.scope) == finished, "final batch persisted with chained expected-byte CAS")
        try VortxNativeWatchedArchive.validate(finished, scope: T.scope)
        try T.processingLimited("80-row eager compatibility expansion") { _ = try VortxNativeWatchedArchive.entries(finished, key: VortxNativeWatchedArchive.evidenceKey) }
        let lookup = try VortxNativeWatchedArchive.evidenceLookup(finished, scope: T.scope)
        let rowScope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: T.scope.account, profileID: T.owner, ownerProfileID: T.owner)
        let retained = try lookup(rowScope, T.digest(source), .authenticatedOwnerLibrary(index: 79))
        T.check(retained.count == 1, "last row has one exact retained receipt after cold resume")
        let retainedSource = try T.object(retained[0])["sourceDocumentBase64"] as? String
        T.check(retainedSource == source.base64EncodedString(), "last row reconstructs exact source after cold resume")
        try T.rejected("stale migration draft CAS") {
            try cold.retainMigrationDraft(saved, scope: T.scope, expected: saved, authority: Authority())
        }
        T.check(try cold.readMigrationDraft(scope: T.scope) == finished, "stale writer leaves durable final data unchanged")
        let lease = Lease(), writes = Counter()
        let cancelled = try VortxNativeWatchedArchive.Stream(archive: empty, scope: T.scope,
            isCurrent: { lease.isCurrent() }, persist: { _ in await writes.increment() })
        try await cancelled.append(retained[0], pending: false)
        lease.revoke()
        do { _ = try await cancelled.finish(); preconditionFailure("Revoked authority wrote a draft") }
        catch LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked {}
        T.check(await writes.value() == 0, "revocation prevents progress publication")

        // Offline rows have no successful receipt or cursor. Preserve every pending original;
        // later historical resolution adds evidence without deleting those original records.
        let unresolved = try VortxNativeWatchedArchive.Stream(archive: empty, scope: T.scope, isCurrent: { true })
        let offline = try await VortxLegacyWatchedMigration.prepare(accountID: T.scope.account, ownerProfileID: T.owner,
            document: source, profileIDs: [T.owner], receiptSink: { try await unresolved.append($0, pending: $1) },
            isCurrent: { true }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        T.check(offline.rows.isEmpty && offline.archives.isEmpty && offline.unresolved.count == 80, "offline rows remain explicitly unresolved")
        let pending = try await unresolved.finish()
        T.check(try count(pending, VortxNativeWatchedArchive.pendingKey) == 80, "all offline originals retained above old aggregate expansion limit")
        let historical = try await VortxNativeWatchedArchive.retryHistorical(pending, scope: T.scope,
            isCurrent: { true }, fetch: { try T.metadata($0) })!
        T.check(try count(historical, VortxNativeWatchedArchive.pendingKey) == 80 && count(historical, VortxNativeWatchedArchive.evidenceKey) == 80,
                "historical completion retains 80 pending originals and 80 accepted receipts")
        T.check(try VortxNativeWatchedArchive.pendingProfileIDs(historical).isEmpty, "only verified matching tuples clear pending display")
        let reread = try await VortxNativeWatchedArchive.retryHistorical(historical, scope: T.scope,
            isCurrent: { true }, fetch: { _ in preconditionFailure("Completed history refetched") })!
        T.check(reread == historical, "completed historical retry is exact-byte idempotent")

        // Actual production callers must feed the sink, not reconstruct eager arrays afterward.
        for file in ["app/SourcesShared/CoreBridge.swift", "app/SourcesShared/VortXSyncManager.swift"] {
            let text = try String(contentsOf: repository.appendingPathComponent(file), encoding: .utf8)
            T.check(text.contains("receiptSink: { try await receiptStream.append($0, pending: $1) }"), "production caller uses streaming sink: \(file)")
            T.check(!text.contains("watched.archives") && !text.contains("watched.pendingArchives"), "production caller does not rebuild eager receipts: \(file)")
            T.check(text.contains("persist: { try await progress.publish($0) }"), "production caller durably checkpoints batches: \(file)")
        }
        print("Watched streaming: 80 exact-source rows, durable crash at 64, cold resume fetched 16, no eager receipt output; 80 pending originals preserved after historical resolution; stale CAS and revocation fail closed")
    }
}

extension VortxNativeWatchedArchive.RecoveryWorker {
    /// Actor-isolated test extension exercises the production actor without a test-only
    /// validation bypass or a production callback capable of certifying archive bytes.
    func assertOffMainExecutorForTest() throws {
        VortxNativeWatchedArchiveTests.check(!Thread.isMainThread, "recovery actor executor is off the main thread in this macOS harness")
    }
}
