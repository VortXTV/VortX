import XCTest
@testable import VortXTV

private actor CredentialCommitSuspension {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class MemoryCredentialTokenStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var storage: CredentialTokenStorage {
        CredentialTokenStorage(
            read: { [weak self] account, _, scope in
                self?.read(account: account, scope: scope)
            },
            write: { [weak self] value, account, scope in
                self?.write(value, account: account, scope: scope) ?? false
            }
        )
    }

    func read(account: String, scope: CredentialScope) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(account: account, scope: scope)]
    }

    private func write(_ value: String?, account: String, scope: CredentialScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[key(account: account, scope: scope)] = value
        return true
    }

    private func key(account: String, scope: CredentialScope) -> String {
        account + "." + scope.storageNamespace
    }
}

@MainActor
final class CredentialOwnerScopingRaceTests: XCTestCase {
    private let accountA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let accountB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    private func authority(_ scope: CredentialScope = .signedOutDevice) -> CredentialScopeAuthority {
        CredentialScopeAuthority(initialScope: scope)
    }

    private func expectDiscard(
        _ authority: CredentialScopeAuthority,
        stamp: CredentialCommitStamp,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var writes = 0
        let result = authority.commitIfCurrent(stamp) { writes += 1 }
        XCTAssertNil(result, file: file, line: line)
        XCTAssertEqual(writes, 0, file: file, line: line)
    }

    func testRegisterACompletesAfterSignInB() {
        let gate = authority(.account(accountA))
        let registerA = gate.beginOperation(.vortxRegister)
        _ = gate.beginOperation(.vortxSignIn)
        expectDiscard(gate, stamp: gate.commitStamp(operation: registerA))
    }

    func testSignInACompletesAfterSignOut() {
        let gate = authority(.account(accountA))
        let signInA = gate.beginOperation(.vortxSignIn)
        gate.transition(to: .signedOutDevice)
        expectDiscard(gate, stamp: CredentialCommitStamp(operation: signInA))
    }

    func testRecoveryACompletesAfterQRB() {
        let gate = authority(.account(accountA))
        let recoveryA = gate.beginOperation(.vortxRecovery)
        _ = gate.beginOperation(.vortxQR)
        expectDiscard(gate, stamp: gate.commitStamp(operation: recoveryA))
    }

    func testQRACompletesAfterNewQRSessionB() {
        let gate = authority(.account(accountA))
        let qrA = gate.beginOperation(.vortxQR)
        _ = gate.beginOperation(.vortxQR)
        expectDiscard(gate, stamp: gate.commitStamp(operation: qrA))
    }

    func testSyncDownACompletesAfterScopeB() {
        let gate = authority(.account(accountA))
        let slotA = gate.transitionStremioSlot(profileID: accountA, account: "slot-a")
        let docA = gate.observePulledDocument(ciphertext: "cipher-a", version: 10, stremioSlot: slotA)
        gate.transition(to: .account(accountB))
        expectDiscard(gate, stamp: CredentialCommitStamp(document: docA))
    }

    func testSyncDownDeferredChildrenCannotMutateB() {
        let gate = authority(.account(accountA))
        let stampA = gate.commitStamp()
        gate.transition(to: .account(accountB))
        for _ in CredentialMutationDomain.allCases {
            expectDiscard(gate, stamp: stampA)
        }
    }

    func testSyncUpAStopsBeforeCredentialBearingPUT() {
        let gate = authority(.account(accountA))
        let stampA = gate.commitStamp()
        gate.transition(to: .account(accountB))
        expectDiscard(gate, stamp: stampA)
    }

    func testIssuedPushACompletionCannotStampB() {
        let gate = authority(.account(accountA))
        let stampA = gate.commitStamp()
        var issued = true
        gate.transition(to: .account(accountB))
        var successStamps = 0
        _ = gate.commitIfCurrent(stampA) { successStamps += 1 }
        XCTAssertTrue(issued)
        XCTAssertEqual(successStamps, 0)
        issued = false
    }

    func testTraktPollAndRefreshAStopBeforeCommitUnderB() {
        let gate = authority(.account(accountA))
        let pollA = gate.beginOperation(.traktDevicePoll)
        let refreshA = gate.beginOperation(.traktRefresh)
        gate.transition(to: .account(accountB))
        expectDiscard(gate, stamp: CredentialCommitStamp(operation: pollA))
        expectDiscard(gate, stamp: CredentialCommitStamp(operation: refreshA))
    }

    func testTrakt401RecoveryCannotClearB() {
        let gate = authority(.account(accountA))
        let recoveryA = gate.beginOperation(.traktRecovery)
        gate.transition(to: .account(accountB))
        expectDiscard(gate, stamp: CredentialCommitStamp(operation: recoveryA))
    }

    func testSIMKLPollACannotCommitUnderB() {
        let gate = authority(.account(accountA))
        let pollA = gate.beginOperation(.simklPinPoll)
        gate.transition(to: .account(accountB))
        expectDiscard(gate, stamp: CredentialCommitStamp(operation: pollA))
    }

    func testCoreBridgeAddAndLogoutAStopUnderB() {
        let gate = authority(.account(accountA))
        let slotA = gate.transitionStremioSlot(profileID: accountA, account: "slot-a")
        let addA = gate.beginOperation(.coreCatalogMutation)
        let stampA = gate.commitStamp(stremioSlot: slotA, operation: addA)
        gate.transition(to: .account(accountB))
        expectDiscard(gate, stamp: stampA)
    }

    func testProfileImportRepairAStopsUnderB() {
        let gate = authority(.account(accountA))
        let slotA = gate.transitionStremioSlot(profileID: accountA, account: "slot-a")
        let importA = gate.beginOperation(.profileSync)
        let stampA = gate.commitStamp(stremioSlot: slotA, operation: importA)
        _ = gate.transitionStremioSlot(profileID: accountB, account: "slot-b")
        expectDiscard(gate, stamp: stampA)
    }

    func testMediaIPTVAndAPIKeyRemoteApplyAStopsUnderB() {
        let gate = authority(.account(accountA))
        let stampA = gate.commitStamp()
        gate.transition(to: .account(accountB))
        for domain in [CredentialMutationDomain.apiKeys, .mediaServers, .iptv] {
            var committed: [CredentialMutationDomain] = []
            _ = gate.commitIfCurrent(stampA) { committed.append(domain) }
            XCTAssertTrue(committed.isEmpty)
        }
    }

    func testDebridBPreventsNewAIssuanceAndAPublication() {
        let store = CredentialLinearizationStore(initialGeneration: 1)
        let a = store.token()
        XCTAssertTrue(store.publish(generation: 2))
        var issued = false
        XCTAssertFalse(a.authorizeAndIssue { issued = true })
        XCTAssertFalse(issued)
        var published = false
        XCTAssertFalse(a.compareAndPublish { published = true })
        XCTAssertFalse(published)
    }

    func testLegacyAndUUIDRulesFailClosed() {
        XCTAssertEqual(CredentialScope(canonicalRemoteAccountID: accountA.uuidString.lowercased()), .account(accountA))
        XCTAssertNil(CredentialScope(canonicalRemoteAccountID: accountA.uuidString))
        XCTAssertNil(CredentialScope(canonicalRemoteAccountID: "{\(accountA.uuidString.lowercased())}"))
        XCTAssertNil(CredentialScope(canonicalRemoteAccountID: accountA.uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        XCTAssertNil(CredentialScope(canonicalRemoteAccountID: " \(accountA.uuidString.lowercased()) "))
        XCTAssertNil(CredentialScope(canonicalRemoteAccountID: "not-an-account"))

        let gate = authority(.signedOutDevice)
        let signedOut = gate.commitStamp()
        gate.transition(to: .account(accountA))
        expectDiscard(gate, stamp: signedOut)
    }

    func testCoordinatorPendingAIsAnnulledWhenBPublishes() async {
        let snapshotA = DebridCredentialSnapshot(
            owner: .account(accountA),
            revision: 1,
            keys: [.realDebrid: "credential-a"]
        )
        let snapshotB = DebridCredentialSnapshot(
            owner: .account(accountB),
            revision: 2,
            keys: [.torBox: "credential-b"]
        )
        let store = DebridCredentialSnapshotStore(initial: snapshotA)
        let suspension = CredentialCommitSuspension()
        let coordinator = DebridCoordinator(
            credentialStore: store,
            onBeforeReloadCommit: { snapshot in
                if snapshot.revision == snapshotA.revision { await suspension.suspend() }
            }
        )

        let staleReload = Task { await coordinator.reload(snapshot: snapshotA) }
        await suspension.waitUntilEntered()
        XCTAssertTrue(store.publish(snapshotB))

        await suspension.release()
        let staleReloadAccepted = await staleReload.value
        let staleGeneration = await coordinator.resolverGeneration(pinning: snapshotA.revision)
        XCTAssertFalse(staleReloadAccepted)
        XCTAssertNil(staleGeneration)

        let currentReload = Task { await coordinator.reload(snapshot: snapshotB) }
        let currentReloadAccepted = await currentReload.value
        let finalGeneration = await coordinator.resolverGeneration(pinning: snapshotB.revision)
        XCTAssertTrue(currentReloadAccepted)
        XCTAssertEqual(finalGeneration?.revision, snapshotB.revision)
    }

    func testTraktInjectedCommitSuspensionRejectsAAfterOwnerB() async {
        let scopeA = CredentialScope.account(UUID())
        let scopeB = CredentialScope.account(UUID())
        let tokenStore = MemoryCredentialTokenStorage()
        let slots = [
            "vortx.trakt.accessToken",
            "vortx.trakt.refreshToken",
            "vortx.trakt.expiresAt",
            "vortx.trakt.createdAt",
        ]
        defer {
            CredentialScopeAuthority.shared.transition(to: .signedOutDevice)
        }

        CredentialScopeAuthority.shared.transition(to: scopeA)
        let stampA = CredentialScopeAuthority.shared.commitStamp()
        let suspension = CredentialCommitSuspension()
        let auth = TraktAuth(
            tokenStorage: tokenStore.storage,
            onBeforeCommit: { await suspension.suspend() }
        )
        let adoption = Task {
            await auth.adoptTokens(
                access: "access-a",
                refresh: "refresh-a",
                expiryUnix: 4_102_444_800,
                credentialStamp: stampA
            )
        }

        await suspension.waitUntilEntered()
        CredentialScopeAuthority.shared.transition(to: scopeB)
        await suspension.release()
        await adoption.value

        for scope in [scopeA, scopeB] {
            for slot in slots {
                XCTAssertNil(tokenStore.read(account: slot, scope: scope))
            }
        }
    }

    func testSIMKLInjectedCommitSuspensionRejectsAAfterOwnerB() async {
        let scopeA = CredentialScope.account(UUID())
        let scopeB = CredentialScope.account(UUID())
        let tokenStore = MemoryCredentialTokenStorage()
        let slots = ["vortx.simkl.accessToken", "vortx.simkl.expiresAt"]
        defer {
            CredentialScopeAuthority.shared.transition(to: .signedOutDevice)
        }

        CredentialScopeAuthority.shared.transition(to: scopeA)
        let stampA = CredentialScopeAuthority.shared.commitStamp()
        let suspension = CredentialCommitSuspension()
        let auth = SIMKLAuth(
            tokenStorage: tokenStore.storage,
            onBeforeCommit: { await suspension.suspend() }
        )
        let adoption = Task {
            await auth.adoptTokens(
                access: "access-a",
                expiryUnix: 0,
                credentialStamp: stampA
            )
        }

        await suspension.waitUntilEntered()
        CredentialScopeAuthority.shared.transition(to: scopeB)
        await suspension.release()
        await adoption.value

        for scope in [scopeA, scopeB] {
            for slot in slots {
                XCTAssertNil(tokenStore.read(account: slot, scope: scope))
            }
        }
    }
}
