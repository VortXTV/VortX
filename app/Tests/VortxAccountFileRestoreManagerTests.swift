import Foundation

@main
private enum VortxAccountFileRestoreManagerTests {
    typealias Result = VortxAccountFileRestoreResult
    typealias Failure = VortxAccountFileRestoreFailure
    @MainActor static func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: " + message) }
    @MainActor static func fresh() throws -> (VortXSyncManager, RestoreFixtureWorld) {
        let world = RestoreFixtureWorld(); RestoreFixtureWorld.current = world
        world.currentHead = try RestoreFixtureValues.head()
        _ = CredentialScopeRegistry.shared.fixtureEstablish(.account(UUID(uuidString: RestoreFixtureValues.accountID)!))
        CoreBridge.shared.hasNativeSession = false; Keychain.result = .missing
        VortXSyncManager.fixtureSawV2 = false; VortXSyncManager.writeSyncDocV2 = false
        return (VortXSyncManager(), world)
    }
    static func id(_ result: Result) -> UUID? {
        switch result {
        case .notSubmitted: return nil
        case .conflict(let id), .deliveryUnconfirmed(let id), .uploadAccepted(let id), .serverConfirmed(let id, _): return id
        }
    }
    static func isNotSubmitted(_ result: Result, _ failure: Failure? = nil) -> Bool {
        if case .notSubmitted(let actual) = result { return failure == nil || actual == failure }
        return false
    }
    static func isUnconfirmed(_ result: Result) -> Bool { if case .deliveryUnconfirmed = result { return true }; return false }
    static func isAccepted(_ result: Result) -> Bool { if case .uploadAccepted = result { return true }; return false }
    static func isConfirmed(_ result: Result) -> Bool { if case .serverConfirmed(_, revision: 25) = result { return true }; return false }
    @MainActor static func finished(_ manager: VortXSyncManager, _ world: RestoreFixtureWorld, _ label: String) {
        check(!manager.fixtureHasOperation(), label + " releases owned slot only after return")
        check(manager.lastSyncedVersion == 20 && !CoreBridge.shared.hasNativeSession,
            label + " does not advance sync floor or claim local adoption")
    }
    @MainActor static func main() async throws {
        do {
            let (manager, world) = try fresh()
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isConfirmed(result), "matching actual readback is server-confirmed")
            check(world.putCount == 1 && world.getCount == 3 && world.prepareCount == 1 && world.retainCount == 1,
                "one prepared candidate one retained intent one PUT and fresh/readback GETs")
            let entry = world.entries[id(result)!]!
            check(entry.intent.selectedFile == world.selectedFile && entry.intent.candidateFile == world.selectedFile,
                "manager retains exact bytes supplied by explicit prep seam")
            check(entry.intent.replacedHeadResponse != world.currentHead && entry.intent.baseRevision == 24 && entry.intent.revision == 25,
                "retained replaced head and candidate ancestry remain distinct")
            check(world.renewalCalls == 1 && manager.token == "synthetic-renewed", "same-owner successful PUT keeps normal renewal callback")
            finished(manager, world, "confirmed")
        }
        let preSend = ["journal.unresolved", "GET.1", "worker", "absence.1", "GET.2", "journal.retain", "absence.2"]
        for boundary in preSend {
            for mutation in ["key", "account", "same-value-epoch", "authentication", "cancel"] {
                let (manager, world) = try fresh(); let box = RestoreFixtureTaskBox()
                world.onBoundary = { hit in
                    guard hit == boundary else { return }
                    switch mutation {
                    case "key": manager.dataKey = Data(repeating: 0x42, count: 32)
                    case "account": manager.fixtureChangeOwner()
                    case "same-value-epoch": manager.fixtureChangeOwner(sameValue: true)
                    case "authentication": manager.fixtureRevokeAuthentication()
                    default: box.task?.cancel()
                    }
                }
                box.task = Task { await manager.restoreAccountBackupFile(world.selectedFile) }
                let result = await box.task!.value
                check(isNotSubmitted(result) && world.putCount == 0, mutation + " at " + boundary + " forbids PUT")
                check(world.renewalCalls == 0, mutation + " at " + boundary + " cannot renew a replacement owner")
                if let entry = world.entries.values.first {
                    check(entry.intent.accountID == RestoreFixtureValues.accountID && entry.key == RestoreFixtureValues.key,
                        mutation + " at " + boundary + " retained evidence stays under original owner/key")
                    check(entry.verdict == .notSubmitted, mutation + " at " + boundary + " records known no-send")
                }
                finished(manager, world, mutation + " at " + boundary)
            }
        }
        // Cancellation cannot free a slot while a noncooperative actor still owns the input.
        do {
            let (manager, world) = try fresh(); world.pausedBoundary = "worker"
            let first = Task { await manager.restoreAccountBackupFile(world.selectedFile) }
            await world.waitFor("worker"); let owned = manager.fixtureOperationID()
            first.cancel()
            check(manager.fixtureHasOperation() && !manager.fixtureFenceActive(), "cancel revokes fence while retaining worker slot")
            let second = await manager.restoreAccountBackupFile(Data("second".utf8))
            check(isNotSubmitted(second, .busy) && manager.fixtureOperationID() == owned, "overlapping restore cannot replace cancelled worker owner")
            let verification = await manager.verifyAccountBackupFileRestore(UUID())
            check(isNotSubmitted(verification, .busy) && manager.fixtureOperationID() == owned,
                "verification cannot replace a still-draining worker owner")
            world.release(); let result = await first.value
            check(isNotSubmitted(result, .cancelled) && world.putCount == 0, "released noncooperative worker cannot submit after cancellation")
            finished(manager, world, "noncooperative worker")
        }
        for boundary in ["PUT", "journal.record.uploadAccepted", "GET.3"] {
            for mutation in ["key", "account", "same-value-epoch", "authentication", "cancel"] {
                let (manager, world) = try fresh(); let box = RestoreFixtureTaskBox()
                world.onBoundary = { hit in
                    guard hit == boundary else { return }
                    switch mutation {
                    case "key": manager.dataKey = Data(repeating: 0x42, count: 32)
                    case "account": manager.fixtureChangeOwner()
                    case "same-value-epoch": manager.fixtureChangeOwner(sameValue: true)
                    case "authentication": manager.fixtureRevokeAuthentication()
                    default: box.task?.cancel()
                    }
                }
                box.task = Task { await manager.restoreAccountBackupFile(world.selectedFile) }
                let result = await box.task!.value
                check(world.putCount == 1, mutation + " at " + boundary + " never retries sent PUT")
                check(boundary == "PUT" ? isUnconfirmed(result) : isAccepted(result),
                    mutation + " at " + boundary + " retains only facts already observed")
                if boundary == "PUT" { check(world.renewalCalls == 0, "stale PUT return cannot renew token") }
                finished(manager, world, mutation + " at " + boundary)
            }
        }
        // Final receipt storage may finish after cancellation: it records an ALREADY witnessed
        // original-account server fact, not adoption/current-owner authority or another network send.
        do {
            let (manager, world) = try fresh(); let box = RestoreFixtureTaskBox()
            world.onBoundary = { if $0 == "journal.record.serverConfirmed" { box.task?.cancel() } }
            box.task = Task { await manager.restoreAccountBackupFile(world.selectedFile) }
            let result = await box.task!.value
            check(isConfirmed(result) && world.putCount == 1, "cancellation after confirmed GET does not erase original server fact")
            finished(manager, world, "final receipt cancellation")
        }
        for sameRevision in [false, true] {
            let (manager, world) = try fresh()
            world.onBoundary = { if $0 == "GET.2" { world.currentHead = try! RestoreFixtureValues.head(revision: sameRevision ? 24 : 25) } }
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isNotSubmitted(result, .staleHead) && world.putCount == 0 && world.retainCount == 0,
                "fresh head changed " + (sameRevision ? "ciphertext" : "revision") + " refuses before retention/send")
        }
        for behavior in [RestoreFixtureWorld.PutBehavior.conflict, .http409, .ambiguousNotDelivered, .throwsNotDelivered, .ambiguousDelivered, .throwsDelivered] {
            let (manager, world) = try fresh(); world.putBehavior = behavior
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            switch behavior {
            case .conflict:
                if case .conflict = result { check(true, "explicit false verdict reports conflict") } else { preconditionFailure("lost explicit conflict") }
                check(world.getCount == 2, "explicit conflict does not invent accepted readback")
            case .http409: check(isUnconfirmed(result), "HTTP409 without admitted Boolean verdict remains conservative and unreplayed")
            case .ambiguousNotDelivered, .throwsNotDelivered: check(isUnconfirmed(result), "unconfirmed delivery with old readback stays unresolved")
            case .ambiguousDelivered, .throwsDelivered: check(isConfirmed(result), "ambiguous PUT can be confirmed only by actual matching GET")
            case .accepted: preconditionFailure("case outside fixture table")
            }
            check(world.putCount == 1, "all verdict classes make at most one PUT")
            finished(manager, world, "delivery class")
        }
        do {
            let (manager, world) = try fresh(); world.putBehavior = .ambiguousNotDelivered
            let first = await manager.restoreAccountBackupFile(world.selectedFile); let originalID = id(first)!
            _ = CredentialScopeRegistry.shared.fixtureEstablish(.account(UUID(uuidString: RestoreFixtureValues.accountID)!))
            let restarted = VortXSyncManager(); let gets = world.getCount
            let blocked = await restarted.restoreAccountBackupFile(Data("new selected bytes".utf8))
            check(isUnconfirmed(blocked) && id(blocked) == originalID && world.putCount == 1 && world.getCount == gets,
                "restarted manager surfaces unresolved original UUID without GET or resend")
            let retained = world.entries[originalID]!.intent
            world.currentHead = try JSONSerialization.data(withJSONObject: ["document": retained.submittedDocument, "version": retained.revision])
            let verified = await restarted.verifyAccountBackupFileRestore(originalID)
            check(isConfirmed(verified) && world.putCount == 1 && world.getCount == gets + 1, "verification uses retained identity and GET only")
            let again = await restarted.restoreAccountBackupFile(world.selectedFile)
            check(isUnconfirmed(again) && id(again) == originalID && world.putCount == 1, "confirmed cloud copy still cannot replay before local adoption receipt")
            finished(restarted, world, "restart verification")
        }
        for boundary in ["journal.load", "GET.4"] {
            for mutation in ["key", "same-value-epoch", "cancel"] {
                let (manager, world) = try fresh(); world.putBehavior = .ambiguousNotDelivered
                let original = await manager.restoreAccountBackupFile(world.selectedFile); let originalID = id(original)!
                let box = RestoreFixtureTaskBox()
                world.onBoundary = { hit in
                    guard hit == boundary else { return }
                    if mutation == "key" { manager.dataKey = Data(repeating: 0x42, count: 32) }
                    else if mutation == "same-value-epoch" { manager.fixtureChangeOwner(sameValue: true) }
                    else { box.task?.cancel() }
                }
                box.task = Task { await manager.verifyAccountBackupFileRestore(originalID) }
                let result = await box.task!.value
                check(isUnconfirmed(result) && id(result) == originalID && world.putCount == 1,
                    mutation + " at verify " + boundary + " keeps original uncertainty and never uploads")
                finished(manager, world, "verification ownership")
            }
        }
        for readbackStatus in [200, 503] {
            let (manager, world) = try fresh()
            world.onBoundary = { hit in
                if hit == "GET.3" {
                    world.getStatus = readbackStatus
                    if readbackStatus == 200 { world.currentHead = try! RestoreFixtureValues.head() }
                }
            }
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isAccepted(result) && world.putCount == 1, "known acceptance without matching readback is not server confirmation")
            finished(manager, world, "accepted readback unavailable")
        }
        do {
            let (manager, world) = try fresh(); world.failRecord = true
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isConfirmed(result) && world.entries[id(result)!]?.verdict == nil,
                "receipt write failure does not invent durable adoption despite witnessed GET")
            let next = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isUnconfirmed(next) && id(next) == id(result) && world.putCount == 1,
                "missing durable result receipt cannot permit replay")
        }
        do {
            let (manager, world) = try fresh()
            world.onBoundary = { if $0 == "GET.1" { manager.token = "synthetic-normal-renewal" } }
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isConfirmed(result) && world.renewalCalls == 1,
                "same-owner token maintenance does not invalidate immutable account/key capture")
        }
        for afterRetention in [false, true] {
            let (manager, world) = try fresh(); world.failRetainBefore = !afterRetention; world.failRetainAfter = afterRetention
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isNotSubmitted(result, .recoveryUnavailable) && world.putCount == 0, "failed journal retention cannot reach PUT")
            if afterRetention {
                world.failRetainAfter = false
                let restart = VortXSyncManager()
                let next = await restart.restoreAccountBackupFile(world.selectedFile)
                check(isUnconfirmed(next) && world.putCount == 0, "ambiguous retention remains unresolved across new operation")
            }
        }
        do {
            let (manager, world) = try fresh(); world.getStatus = 404
            check(isNotSubmitted(await manager.restoreAccountBackupFile(world.selectedFile), .noCloudBackup) && world.putCount == 0,
                "missing cloud backup does not fabricate owner permission")
        }
        do {
            let (manager, world) = try fresh(); world.preparationRefusal = .currentAccountUnsupported
            check(isNotSubmitted(await manager.restoreAccountBackupFile(world.selectedFile), .modernAccount) && world.putCount == 0,
                "modern remote account does not enter legacy replacement")
        }
        for refusal in [Failure.currentNativeState, .localStateUnverifiable, .pendingLocalChanges] {
            let (manager, world) = try fresh(); world.absenceRefusal = refusal
            check(isNotSubmitted(await manager.restoreAccountBackupFile(world.selectedFile), refusal) && world.putCount == 0,
                "existing/unverifiable/pending local state cannot submit")
        }
        for keychain in [CredentialDurableReadResult.value("synthetic-existing"), .failure] {
            let (manager, world) = try fresh(); Keychain.result = keychain
            check(isNotSubmitted(await manager.restoreAccountBackupFile(world.selectedFile)) && world.putCount == 0 && world.getCount == 0,
                "non-missing provider state never proves eligibility")
        }
        do {
            let (manager, world) = try fresh(); world.onBoundary = { if $0 == "GET.2" { manager.dirtySettings["synthetic"] = 1 } }
            let result = await manager.restoreAccountBackupFile(world.selectedFile)
            check(isNotSubmitted(result, .pendingLocalChanges) && world.putCount == 0 && manager.dirtySettings["synthetic"] == 1,
                "new pending edit is preserved and refuses submission")
        }
        do {
            let (manager, world) = try fresh(); manager.lastSyncedVersion = 25
            check(isNotSubmitted(await manager.restoreAccountBackupFile(world.selectedFile), .staleHead) && world.putCount == 0,
                "cloud head below original local floor cannot submit")
        }
        print("All unchanged-source account file restore manager orchestration checks passed with explicit synthetic collaborators.")
    }
}
