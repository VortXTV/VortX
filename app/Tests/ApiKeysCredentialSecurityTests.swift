// Standalone adversarial executable for owner-scoped metadata and SkipDB credentials.
//
// Run with:
//   swiftc -D CREDENTIAL_RETRY_COORDINATOR_STANDALONE \
//     -swift-version 5 -strict-concurrency=complete -warnings-as-errors -o /tmp/api-keys-security \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/VortXSyncManager.swift \
//     app/SourcesShared/ApiKeys.swift \
//     app/Tests/ApiKeysCredentialSecurityTests.swift && /tmp/api-keys-security

import Foundation

// Injectable production seams for compiling the real ApiKeys.swift without the full app target.
enum Keychain {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: String] = [:]
        var ignoredWrites = Set<String>()
        var failedWrites = Set<String>()
        var ignoredDeletes = Set<String>()
        var ignoredReads = Set<String>()
        var failedReads = Set<String>()
        var invalidated = Set<String>()
        var failAfterPersistWrites = Set<String>()
        var writeCount = 0
        var writeAccounts: [String] = []
        var deleteAccounts: [String] = []
        var readCount: [String: Int] = [:]
    }
    private static let storage = Storage()

    static func reset() {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.values.removeAll()
        storage.ignoredWrites.removeAll()
        storage.failedWrites.removeAll()
        storage.ignoredDeletes.removeAll()
        storage.ignoredReads.removeAll()
        storage.failedReads.removeAll()
        storage.invalidated.removeAll()
        storage.failAfterPersistWrites.removeAll()
        storage.writeCount = 0
        storage.writeAccounts.removeAll()
        storage.deleteAccounts.removeAll()
        storage.readCount.removeAll()
    }
    static func string(_ account: String) -> String? {
        switch durableString(account) {
        case let .value(value): return value
        case .missing, .failure: return nil
        }
    }
    static func durableString(_ account: String) -> CredentialDurableReadResult {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.readCount[account, default: 0] += 1
        if storage.failedReads.contains(account) || storage.ignoredReads.remove(account) != nil {
            return .failure
        }
        if let value = storage.values[account] { return .value(value) }
        return .missing
    }
    static func confirmedString(_ account: String) -> CredentialDurableReadResult {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.readCount[account, default: 0] += 1
        if storage.invalidated.contains(account)
            || storage.failedReads.contains(account)
            || storage.ignoredReads.remove(account) != nil {
            return .failure
        }
        if let value = storage.values[account] { return .value(value) }
        return .missing
    }
    @discardableResult
    static func set(_ value: String?, for account: String) -> CredentialMutationResult {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.writeCount += 1
        storage.writeAccounts.append(account)
        if value == nil { storage.deleteAccounts.append(account) }
        let persistedThenFailed = storage.failAfterPersistWrites.contains(account)
        if value != nil,
           storage.failedWrites.contains(account) || storage.ignoredWrites.remove(account) != nil {
            storage.invalidated.insert(account)
            return .failure
        }
        if value == nil, storage.ignoredDeletes.remove(account) != nil {
            storage.invalidated.insert(account)
            return .failure
        }
        if let value { storage.values[account] = value }
        else { storage.values.removeValue(forKey: account) }
        if persistedThenFailed {
            storage.invalidated.insert(account)
            return .failure
        }
        storage.invalidated.remove(account)
        return .success
    }
    static func failNextWrite(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.ignoredWrites.insert(account)
    }
    static func failWrites(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.failedWrites.insert(account)
    }
    static func failNextDelete(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.ignoredDeletes.insert(account)
    }
    static func failNextRead(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.ignoredReads.insert(account)
    }
    static func failReads(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.failedReads.insert(account)
    }
    static func failAfterPersist(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.failAfterPersistWrites.insert(account)
    }
    static func repairAfterPersist(for account: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.failAfterPersistWrites.remove(account)
    }
    static func readCount(for account: String) -> Int {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.readCount[account, default: 0]
    }
    static var totalWriteCount: Int {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.writeCount
    }
    static func writeCount(for account: String) -> Int {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.writeAccounts.filter { $0 == account }.count
    }
    static func deleteCount(for account: String) -> Int {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.deleteAccounts.filter { $0 == account }.count
    }
}

@MainActor
final class VortXSyncManager {
    static let shared = VortXSyncManager()
    private static var requests = 0
    static var syncRequests: Int { requests }
    static func resetSyncRequests() { requests = 0 }
    func requestSyncSoon() { Self.requests += 1 }
}

private struct SourceContracts {
    let apiKeys: String
    let syncManager: String
    let credentialScope: String
}

private func source(_ relativePath: String) -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = testsDirectory.deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
}

private func contracts() -> SourceContracts {
    SourceContracts(
        apiKeys: source("SourcesShared/ApiKeys.swift"),
        syncManager: source("SourcesShared/VortXSyncManager.swift"),
        credentialScope: source("SourcesShared/CredentialScope.swift"))
}

private enum RuntimeRestoreEvent: Equatable {
    case deleteMalformedValue
    case bindOwner
    case authenticateOwner
    case migrateCredentials
}

private enum OwnerCompositionEvent: Equatable {
    case acquireOwner
    case bindCredentialStores
    case sourceIndexWillMutate
    case publishSession
    case establishAuthenticatedOwner
    case claimTraktLegacySlots
    case finalizeTraktLegacySlots
    case claimSIMKLLegacySlots
    case finalizeSIMKLLegacySlots
}

private struct OwnerAcquisitionTrace: Equatable {
    let deniedAttemptLogs: [Int]
    let exhaustedLogs: Int
    let successfulApplications: Int
}

private enum SignOutDurabilityEvent: Equatable {
    case checkFence
    case deleteSession
    case bindOwners
    case publishSignedOut
}

private enum AdoptDurabilityEvent: Equatable {
    case certifySession
    case bindOwners
    case establishOwner
    case sourceIndexWillMutate
    case publishSession
}

@MainActor
private final class SignOutDurabilityProbe {
    let accountScope = CredentialScope(
        canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let registry: CredentialScopeRegistry
    private(set) var apiKeysOwner: CredentialScope
    private(set) var debridOwner: CredentialScope
    private(set) var publishedSignedOut = false
    private(set) var events: [SignOutDurabilityEvent] = []
    var deleteResult: CredentialMutationResult = .failure
    var invalidateFenceDuringDelete = false

    init() {
        registry = CredentialScopeRegistry(initialScope: accountScope)
        apiKeysOwner = accountScope
        debridOwner = accountScope
    }

    var capture: CredentialScopeRegistry.Capture { registry.capture() }

    func attempt(_ expected: CredentialScopeRegistry.Capture) -> Bool {
        CredentialSignOutCoordinator.complete(
            isPreSignOutCurrent: { [self] in
                events.append(.checkFence)
                return registry.isCurrent(expected)
            },
            deletePersistedSession: { [self] in
                events.append(.deleteSession)
                if invalidateFenceDuringDelete {
                    _ = registry.bind(accountScope)
                }
                return deleteResult
            },
            bindSignedOutOwner: { [self] in
                events.append(.bindOwners)
                guard let signedOut = registry.tryBind(.signedOutDevice) else { return false }
                apiKeysOwner = signedOut.scope
                debridOwner = signedOut.scope
                return true
            },
            publishSignedOutState: { [self] in
                events.append(.publishSignedOut)
                publishedSignedOut = true
            })
    }
}

@MainActor
private func executableSignOutDurabilityScenarios() -> (
    failedDeletePreservesOwners: Bool,
    staleAfterDeletePreservesOwners: Bool,
    busyBindPreservesAndRetries: Bool
) {
    let failedDelete = SignOutDurabilityProbe()
    let failedCapture = failedDelete.capture
    let failedResult = failedDelete.attempt(failedCapture)
    let failedDeletePreservesOwners = !failedResult
        && failedDelete.registry.isCurrent(failedCapture)
        && failedDelete.apiKeysOwner == failedDelete.accountScope
        && failedDelete.debridOwner == failedDelete.accountScope
        && !failedDelete.publishedSignedOut
        && failedDelete.events == [.checkFence, .deleteSession]

    let stale = SignOutDurabilityProbe()
    let staleCapture = stale.capture
    stale.deleteResult = .success
    stale.invalidateFenceDuringDelete = true
    let staleResult = stale.attempt(staleCapture)
    let staleAfterDeletePreservesOwners = !staleResult
        && stale.apiKeysOwner == stale.accountScope
        && stale.debridOwner == stale.accountScope
        && !stale.publishedSignedOut
        && stale.events == [.checkFence, .deleteSession, .checkFence]

    let busy = SignOutDurabilityProbe()
    let busyCapture = busy.capture
    busy.deleteResult = .success
    let heldBoundary = CredentialPublicationOutbox.beginBoundary()
    let busyResult = busy.attempt(busyCapture)
    if heldBoundary { CredentialPublicationOutbox.endBoundary() }
    let ownersHeld = !busyResult
        && busy.registry.isCurrent(busyCapture)
        && busy.apiKeysOwner == busy.accountScope
        && busy.debridOwner == busy.accountScope
        && !busy.publishedSignedOut
        && busy.events == [.checkFence, .deleteSession, .checkFence, .bindOwners]
    let retryResult = busy.attempt(busyCapture)
    let busyBindPreservesAndRetries = heldBoundary && ownersHeld && retryResult
        && busy.capture.scope == .signedOutDevice
        && busy.apiKeysOwner == .signedOutDevice
        && busy.debridOwner == .signedOutDevice
        && busy.publishedSignedOut
        && busy.events == [
            .checkFence, .deleteSession, .checkFence, .bindOwners,
            .checkFence, .deleteSession, .checkFence, .bindOwners, .publishSignedOut
        ]

    return (failedDeletePreservesOwners, staleAfterDeletePreservesOwners, busyBindPreservesAndRetries)
}

/// Executable counterpart to the manager source contract: the scope flip is held behind the certified
/// session write, so even an uncertain post-persist result cannot publish an account projection.
@MainActor
private final class AdoptDurabilityProbe {
    let previousScope = CredentialScope(
        canonicalRemoteAccountID: "11111111-1111-1111-1111-111111111111")!
    let candidateScope = CredentialScope(
        canonicalRemoteAccountID: "22222222-2222-2222-2222-222222222222")!
    let registry: CredentialScopeRegistry
    private(set) var apiKeysOwner: CredentialScope
    private(set) var debridOwner: CredentialScope
    private(set) var sourceIndexMutations = 0
    private(set) var token: String?
    private(set) var accountPublished = false
    private(set) var dataKeyPublished = false
    private(set) var isSignedIn = false
    private(set) var events: [AdoptDurabilityEvent] = []

    init() {
        registry = CredentialScopeRegistry(initialScope: previousScope)
        apiKeysOwner = previousScope
        debridOwner = previousScope
    }

    var capture: CredentialScopeRegistry.Capture { registry.capture() }

    func adopt(certifying persistence: () -> CredentialMutationResult) -> Bool {
        guard let capture = registry.tryBind(candidateScope, certifying: { [self] in
            events.append(.certifySession)
            return persistence()
        }) else { return false }
        events.append(.bindOwners)
        apiKeysOwner = capture.scope
        debridOwner = capture.scope
        events.append(.establishOwner)
        sourceIndexMutations += 1
        events.append(.sourceIndexWillMutate)
        token = "candidate-token"
        accountPublished = true
        dataKeyPublished = true
        isSignedIn = true
        events.append(.publishSession)
        return true
    }
}

@MainActor
private func executableAdoptDurabilityScenarios() -> (
    failurePreservesProjection: Bool,
    repairThenPublishesOnce: Bool
) {
    let slot = "vortx.sync.adopt-durability-probe"
    Keychain.reset()
    let probe = AdoptDurabilityProbe()
    let before = probe.capture
    Keychain.failAfterPersist(for: slot)
    let failed = probe.adopt {
        Keychain.set("candidate-session", for: slot)
    }
    let failurePreservesProjection = !failed
        && probe.capture == before
        && probe.apiKeysOwner == probe.previousScope
        && probe.debridOwner == probe.previousScope
        && probe.sourceIndexMutations == 0
        && probe.token == nil
        && !probe.accountPublished
        && !probe.dataKeyPublished
        && !probe.isSignedIn
        && probe.events == [.certifySession]
        && Keychain.durableString(slot) == .value("candidate-session")
        && Keychain.confirmedString(slot) == .failure

    Keychain.repairAfterPersist(for: slot)
    let recovered = probe.adopt {
        Keychain.set("candidate-session", for: slot)
    }
    let repairThenPublishesOnce = recovered
        && probe.capture.scope == probe.candidateScope
        && probe.apiKeysOwner == probe.candidateScope
        && probe.debridOwner == probe.candidateScope
        && probe.sourceIndexMutations == 1
        && probe.token == "candidate-token"
        && probe.accountPublished
        && probe.dataKeyPublished
        && probe.isSignedIn
        && probe.events == [
            .certifySession,
            .certifySession, .bindOwners, .establishOwner,
            .sourceIndexWillMutate, .publishSession
        ]
        && Keychain.confirmedString(slot) == .value("candidate-session")

    return (failurePreservesProjection, repairThenPublishesOnce)
}

private struct PendingProviderAdoption: Equatable {
    let capture: CredentialScopeRegistry.Capture
    let version: Int
    let trakt: Bool
    let simkl: Bool
}

/// A small executable model of the manager's two named remote provider adoptions. It deliberately keeps a
/// capture-keyed retry only for the provider that failed, so a successful sibling is never re-adopted while
/// the account document remains unacknowledged.
@MainActor
private final class ProviderAdoptionSettlementProbe {
    let primaryScope = CredentialScope(
        canonicalRemoteAccountID: "33333333-3333-3333-3333-333333333333")!
    let replacementScope = CredentialScope(
        canonicalRemoteAccountID: "44444444-4444-4444-4444-444444444444")!
    let registry: CredentialScopeRegistry
    var pending: PendingProviderAdoption?
    var traktFailuresRemaining = 0
    var simklFailuresRemaining = 0
    var switchDuringTrakt = false
    private(set) var traktAttempts = 0
    private(set) var simklAttempts = 0
    private(set) var traktWrites = 0
    private(set) var simklWrites = 0
    private(set) var acknowledgedVersion = 0
    private(set) var hasApplied = false

    init() {
        registry = CredentialScopeRegistry(initialScope: primaryScope)
    }

    private func adoptTrakt(_ capture: CredentialScopeRegistry.Capture) async -> CredentialMutationResult {
        traktAttempts += 1
        if switchDuringTrakt { _ = registry.bind(replacementScope) }
        await Task.yield()
        guard registry.isCurrent(capture) else { return .failure }
        if traktFailuresRemaining > 0 {
            traktFailuresRemaining -= 1
            return .failure
        }
        traktWrites += 1
        return .success
    }

    private func adoptSIMKL(_ capture: CredentialScopeRegistry.Capture) async -> CredentialMutationResult {
        simklAttempts += 1
        await Task.yield()
        guard registry.isCurrent(capture) else { return .failure }
        if simklFailuresRemaining > 0 {
            simklFailuresRemaining -= 1
            return .failure
        }
        simklWrites += 1
        return .success
    }

    func settle(version: Int, hasTrakt: Bool, hasSIMKL: Bool) async -> Bool {
        let capture = registry.capture()
        let intent: PendingProviderAdoption
        if let pending, pending.capture == capture, pending.version == version {
            intent = pending
        } else {
            intent = PendingProviderAdoption(
                capture: capture,
                version: version,
                trakt: hasTrakt,
                simkl: hasSIMKL)
        }

        let outcome = await CredentialRetryCoordinator.finalizeProviders(
            maximumAttempts: 3,
            isCurrent: { self.registry.isCurrent(capture) },
            firstClaim: { intent.trakt },
            firstClaimSucceeded: { _ in true },
            firstNeedsFinalization: { $0 },
            firstFinalize: {
                await self.adoptTrakt(capture) == .success
            },
            secondClaim: { intent.simkl },
            secondClaimSucceeded: { _ in true },
            secondNeedsFinalization: { $0 },
            secondFinalize: {
                await self.adoptSIMKL(capture) == .success
            },
            sleepBeforeRetry: {
                await Task.yield()
                return self.registry.isCurrent(capture)
            })

        guard registry.isCurrent(capture), !outcome.superseded else { return false }
        if !outcome.completed {
            pending = PendingProviderAdoption(
                capture: capture,
                version: version,
                trakt: intent.trakt && !outcome.firstCompleted,
                simkl: intent.simkl && !outcome.secondCompleted)
            return false
        }
        pending = nil
        acknowledgedVersion = max(acknowledgedVersion, version)
        hasApplied = true
        return true
    }
}

@MainActor
private func executableProviderAdoptionSettlementScenarios() async -> (
    traktFailureRemainsPending: Bool,
    simklFailureRemainsPending: Bool,
    asymmetricRetryAvoidsDuplicate: Bool,
    accountSwitchCannotAcknowledgeOrWrite: Bool
) {
    let traktFailure = ProviderAdoptionSettlementProbe()
    traktFailure.traktFailuresRemaining = 3
    let traktFailed = await traktFailure.settle(version: 41, hasTrakt: true, hasSIMKL: false)
    let traktFailureRemainsPending = !traktFailed
        && traktFailure.pending == PendingProviderAdoption(
            capture: traktFailure.registry.capture(), version: 41, trakt: true, simkl: false)
        && traktFailure.acknowledgedVersion == 0
        && !traktFailure.hasApplied
        && traktFailure.traktAttempts == 3
        && traktFailure.traktWrites == 0

    let simklFailure = ProviderAdoptionSettlementProbe()
    simklFailure.simklFailuresRemaining = 3
    let simklFailed = await simklFailure.settle(version: 42, hasTrakt: false, hasSIMKL: true)
    let simklFailureRemainsPending = !simklFailed
        && simklFailure.pending == PendingProviderAdoption(
            capture: simklFailure.registry.capture(), version: 42, trakt: false, simkl: true)
        && simklFailure.acknowledgedVersion == 0
        && !simklFailure.hasApplied
        && simklFailure.simklAttempts == 3
        && simklFailure.simklWrites == 0

    let asymmetric = ProviderAdoptionSettlementProbe()
    asymmetric.simklFailuresRemaining = 3
    let firstAsymmetric = await asymmetric.settle(version: 43, hasTrakt: true, hasSIMKL: true)
    let secondAsymmetric = await asymmetric.settle(version: 43, hasTrakt: true, hasSIMKL: true)
    let asymmetricRetryAvoidsDuplicate = !firstAsymmetric
        && secondAsymmetric
        && asymmetric.traktAttempts == 1
        && asymmetric.traktWrites == 1
        && asymmetric.simklAttempts == 4
        && asymmetric.simklWrites == 1
        && asymmetric.pending == nil
        && asymmetric.acknowledgedVersion == 43
        && asymmetric.hasApplied

    let switched = ProviderAdoptionSettlementProbe()
    switched.switchDuringTrakt = true
    let switchedResult = await switched.settle(version: 44, hasTrakt: true, hasSIMKL: true)
    let accountSwitchCannotAcknowledgeOrWrite = !switchedResult
        && switched.pending == nil
        && switched.acknowledgedVersion == 0
        && !switched.hasApplied
        && switched.traktAttempts == 1
        && switched.traktWrites == 0
        && switched.simklAttempts == 0
        && switched.simklWrites == 0
        && switched.registry.capture().scope == switched.replacementScope

    return (
        traktFailureRemainsPending,
        simklFailureRemainsPending,
        asymmetricRetryAvoidsDuplicate,
        accountSwitchCannotAcknowledgeOrWrite)
}

@MainActor
private final class OwnerRetryExecutionProbe {
    var generation = 0
    var attempts: [Int] = []
    var denied: [Int] = []
    var exhausted = 0
}

@MainActor
private func executableOwnerRetryScenarios() async -> (
    denialThenSuccess: Bool,
    exhaustionLogged: Bool,
    supersessionDrops: Bool,
    retainedTaskCompletes: Bool
) {
    let successProbe = OwnerRetryExecutionProbe()
    let successTask = CredentialRetryCoordinator.launch {
        await CredentialRetryCoordinator.acquireOwner(
            attempts: 1...3,
            isCurrent: { true },
            tryAcquire: { attempt in
                successProbe.attempts.append(attempt)
                return attempt == 3 ? "capture" : nil
            },
            denied: { successProbe.denied.append($0) },
            exhausted: { successProbe.exhausted += 1 },
            sleepBeforeRetry: {
                await Task.yield()
                return true
            })
    }
    let success = await successTask.value
    let acquiredOnThirdAttempt: Bool
    switch success {
    case let .acquired(value): acquiredOnThirdAttempt = value == "capture"
    case .exhausted, .superseded: acquiredOnThirdAttempt = false
    }

    let exhaustionProbe = OwnerRetryExecutionProbe()
    let exhaustion = await CredentialRetryCoordinator.acquireOwner(
        attempts: 1...3,
        isCurrent: { true },
        tryAcquire: { attempt -> String? in
            exhaustionProbe.attempts.append(attempt)
            return nil
        },
        denied: { exhaustionProbe.denied.append($0) },
        exhausted: { exhaustionProbe.exhausted += 1 },
        sleepBeforeRetry: {
            await Task.yield()
            return true
        })
    let exhaustedAfterThree: Bool
    switch exhaustion {
    case .exhausted: exhaustedAfterThree = true
    case .acquired, .superseded: exhaustedAfterThree = false
    }

    let supersededProbe = OwnerRetryExecutionProbe()
    let capturedGeneration = supersededProbe.generation
    let superseded = await CredentialRetryCoordinator.acquireOwner(
        attempts: 1...3,
        isCurrent: { supersededProbe.generation == capturedGeneration },
        tryAcquire: { attempt -> String? in
            supersededProbe.attempts.append(attempt)
            return nil
        },
        denied: { supersededProbe.denied.append($0) },
        exhausted: { supersededProbe.exhausted += 1 },
        sleepBeforeRetry: {
            supersededProbe.generation += 1
            await Task.yield()
            return true
        })
    let droppedAfterSupersession: Bool
    switch superseded {
    case .superseded: droppedAfterSupersession = true
    case .acquired, .exhausted: droppedAfterSupersession = false
    }

    return (
        denialThenSuccess: acquiredOnThirdAttempt
            && successProbe.attempts == [1, 2, 3]
            && successProbe.denied == [1, 2]
            && successProbe.exhausted == 0,
        exhaustionLogged: exhaustedAfterThree
            && exhaustionProbe.attempts == [1, 2, 3]
            && exhaustionProbe.denied == [1, 2, 3]
            && exhaustionProbe.exhausted == 1,
        supersessionDrops: droppedAfterSupersession
            && supersededProbe.attempts == [1]
            && supersededProbe.denied == [1]
            && supersededProbe.exhausted == 0,
        retainedTaskCompletes: successTask.isCancelled == false && acquiredOnThirdAttempt)
}

@MainActor
private final class ProviderRetryExecutionProbe {
    var generation = 0
    var firstClaims = 0
    var secondClaims = 0
    var firstFinalizations = 0
    var secondFinalizations = 0
}

@MainActor
private func executableProviderRetry(
    firstClaimDenials: Int,
    secondClaimDenials: Int
) async -> (completed: Bool, probe: ProviderRetryExecutionProbe) {
    let probe = ProviderRetryExecutionProbe()
    let capturedGeneration = probe.generation
    let outcome = await CredentialRetryCoordinator.finalizeProviders(
        maximumAttempts: 3,
        isCurrent: { probe.generation == capturedGeneration },
        firstClaim: {
            probe.firstClaims += 1
            return probe.firstClaims > firstClaimDenials
        },
        firstClaimSucceeded: { $0 },
        firstNeedsFinalization: { _ in true },
        firstFinalize: {
            probe.firstFinalizations += 1
            await Task.yield()
            return true
        },
        secondClaim: {
            probe.secondClaims += 1
            return probe.secondClaims > secondClaimDenials
        },
        secondClaimSucceeded: { $0 },
        secondNeedsFinalization: { _ in true },
        secondFinalize: {
            probe.secondFinalizations += 1
            await Task.yield()
            return true
        },
        sleepBeforeRetry: {
            await Task.yield()
            return true
        })
    return (outcome.completed, probe)
}

@MainActor
private func executableProviderSupersession() async -> Bool {
    let probe = ProviderRetryExecutionProbe()
    let capturedGeneration = probe.generation
    let outcome = await CredentialRetryCoordinator.finalizeProviders(
        maximumAttempts: 3,
        isCurrent: { probe.generation == capturedGeneration },
        firstClaim: {
            probe.firstClaims += 1
            return true
        },
        firstClaimSucceeded: { $0 },
        firstNeedsFinalization: { _ in true },
        firstFinalize: {
            probe.firstFinalizations += 1
            probe.generation += 1
            await Task.yield()
            return true
        },
        secondClaim: {
            probe.secondClaims += 1
            return true
        },
        secondClaimSucceeded: { $0 },
        secondNeedsFinalization: { _ in true },
        secondFinalize: {
            probe.secondFinalizations += 1
            return true
        },
        sleepBeforeRetry: { true })
    return outcome.superseded
        && !outcome.firstCompleted
        && !outcome.secondCompleted
        && probe.firstClaims == 1
        && probe.firstFinalizations == 1
        && probe.secondClaims == 0
        && probe.secondFinalizations == 0
}

private func runtimeRestoreEvents(
    read: CredentialDurableReadResult,
    persistedValueIsValid: Bool
) -> [RuntimeRestoreEvent] {
    switch read {
    case .failure, .missing:
        return []
    case .value:
        guard persistedValueIsValid else { return [.deleteMalformedValue] }
        return [.bindOwner, .authenticateOwner, .migrateCredentials]
    }
}

/// The session layer must not mutate a single dependent store until the optional owner acquisition succeeds.
/// Provider finalization is separately gated on authenticated ownership and successful raw claims, so passive
/// reads can never manufacture provider sessions or publication state.
private func ownerCompositionEvents(
    ownerAcquired: Bool,
    ownerEstablished: Bool,
    traktRawClaimSucceeded: Bool,
    simklRawClaimSucceeded: Bool
) -> [OwnerCompositionEvent] {
    guard ownerAcquired else { return [] }
    var events: [OwnerCompositionEvent] = [
        .acquireOwner,
        .bindCredentialStores,
        .sourceIndexWillMutate,
        .publishSession
    ]
    guard ownerEstablished else { return events }
    events.append(.establishAuthenticatedOwner)
    if traktRawClaimSucceeded {
        events.append(.claimTraktLegacySlots)
        events.append(.finalizeTraktLegacySlots)
    }
    if simklRawClaimSucceeded {
        events.append(.claimSIMKLLegacySlots)
        events.append(.finalizeSIMKLLegacySlots)
    }
    return events
}

/// Behavioral oracle for the production retry contract: each denial is visible, exhaustion is visible once,
/// and the protected transition applies at most once. Supersession drops the remaining retries without apply.
private func ownerAcquisitionTrace(
    denialsBeforeSuccess: Int,
    supersededAfterAttempt: Int? = nil,
    maximumAttempts: Int = 3
) -> OwnerAcquisitionTrace {
    var denied: [Int] = []
    for attempt in 1...maximumAttempts {
        if let supersededAfterAttempt, attempt > supersededAfterAttempt {
            return OwnerAcquisitionTrace(
                deniedAttemptLogs: denied,
                exhaustedLogs: 0,
                successfulApplications: 0)
        }
        if attempt > denialsBeforeSuccess {
            return OwnerAcquisitionTrace(
                deniedAttemptLogs: denied,
                exhaustedLogs: 0,
                successfulApplications: 1)
        }
        denied.append(attempt)
    }
    return OwnerAcquisitionTrace(
        deniedAttemptLogs: denied,
        exhaustedLogs: 1,
        successfulApplications: 0)
}

private func sourceRegion(_ source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func occursInOrder(_ source: String, _ snippets: [String]) -> Bool {
    var cursor = source.startIndex
    for snippet in snippets {
        guard let range = source.range(of: snippet, range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

private func occurrenceCount(_ source: String, _ snippet: String) -> Int {
    var count = 0
    var cursor = source.startIndex
    while let range = source.range(of: snippet, range: cursor..<source.endIndex) {
        count += 1
        cursor = range.upperBound
    }
    return count
}

private struct ProductionCredentialBodyGateProof {
    let productionAccepted: Bool
    let bindMutationRejected: Bool
    let bindFailureMutationRejected: Bool
    let restoreMutationRejected: Bool
    let restoreDenialMutationRejected: Bool
    let restoreElseMutationRejected: Bool
    let signOutMutationRejected: Bool
    let signOutDenialMutationRejected: Bool
    let signOutElseMutationRejected: Bool
    let adoptMutationRejected: Bool
    let adoptFailureMutationRejected: Bool
    let malformedCleanupMutationRejected: Bool
    let malformedCleanupSessionMutationRejected: Bool
    let harmlessPreludeAccepted: Bool
}

private struct CompilerBodyGateEvaluation {
    let parsed: Bool
    let accepted: Bool
}

private struct CompilerASTStatement {
    let kind: String
    let text: String
}

/// `-dump-parse` omits conditional-compilation bodies, so expose only the two standalone wrappers while
/// preserving every production-body byte and every other compiler condition. The resulting AST is still the
/// compiler's parse of the exact manager implementation, not a reimplemented Swift parser.
private func productionBodyParseProjection(_ source: String) -> String? {
    let standaloneGuard = "#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE"
    var conditionalStack: [Bool] = []
    var removedStandaloneGuards = 0
    var projected: [String] = []

    for line in source.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#if ") {
            let isStandaloneGuard = trimmed == standaloneGuard
            conditionalStack.append(isStandaloneGuard)
            if isStandaloneGuard {
                removedStandaloneGuards += 1
                continue
            }
        } else if trimmed == "#endif" {
            guard let isStandaloneGuard = conditionalStack.popLast() else { return nil }
            if isStandaloneGuard { continue }
        } else if (trimmed == "#else" || trimmed.hasPrefix("#elseif ")),
                  conditionalStack.last == true {
            return nil
        }
        projected.append(line)
    }

    guard conditionalStack.isEmpty, removedStandaloneGuards == 2 else { return nil }
    return projected.joined(separator: "\n")
}

private func compilerParseDump(_ source: String) -> String? {
    guard let projected = productionBodyParseProjection(source) else { return nil }
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("vortx-credential-body-gate-\(UUID().uuidString)", isDirectory: true)
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("VortXSyncManager.swift")
        let stdoutURL = directory.appendingPathComponent("parse.stdout")
        let stderrURL = directory.appendingPathComponent("parse.stderr")
        try projected.write(to: sourceURL, atomically: true, encoding: .utf8)
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil) else { return nil }

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-frontend", "-dump-parse", sourceURL.path]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        guard process.terminationStatus == 0 else { return nil }
        return try String(contentsOf: stdoutURL, encoding: .utf8)
    } catch {
        return nil
    }
}

private func leadingSpaceCount(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
}

private func compilerStatements(
    _ dump: String,
    function signature: String
) -> [CompilerASTStatement]? {
    let lines = dump.components(separatedBy: "\n")
    guard let functionStart = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("(func_decl ")
            && $0.contains("\"\(signature)\"")
    }) else { return nil }

    let functionIndent = leadingSpaceCount(lines[functionStart])
    let functionEnd = lines[(functionStart + 1)...].firstIndex(where: {
        let trimmed = $0.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.hasPrefix("(")
            && leadingSpaceCount($0) <= functionIndent
    }) ?? lines.endIndex
    guard let bodyStart = lines[(functionStart + 1)..<functionEnd].firstIndex(where: {
        leadingSpaceCount($0) == functionIndent + 2
            && $0.trimmingCharacters(in: .whitespaces).hasPrefix("(brace_stmt ")
    }) else { return nil }

    let statementIndent = functionIndent + 4
    let statementStarts = lines[(bodyStart + 1)..<functionEnd].indices.filter {
        let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
        return leadingSpaceCount(lines[$0]) == statementIndent && trimmed.hasPrefix("(")
    }
    guard !statementStarts.isEmpty else { return [] }

    return statementStarts.enumerated().map { offset, start in
        let end = offset + 1 < statementStarts.count ? statementStarts[offset + 1] : functionEnd
        let text = lines[start..<end].joined(separator: "\n")
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let kindEnd = first.firstIndex(where: { $0 == " " || $0 == ")" }) ?? first.endIndex
        return CompilerASTStatement(kind: String(first[..<kindEnd]), text: text)
    }
}

private func compilerNestedBodyStatements(
    _ statement: CompilerASTStatement
) -> [CompilerASTStatement]? {
    let lines = statement.text.components(separatedBy: "\n")
    guard let first = lines.first else { return nil }
    let rootIndent = leadingSpaceCount(first)
    guard let bodyStart = lines.indices.dropFirst().first(where: {
        leadingSpaceCount(lines[$0]) == rootIndent + 2
            && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("(brace_stmt ")
    }) else { return nil }

    let childIndent = rootIndent + 4
    let childStarts = lines.indices.dropFirst(bodyStart + 1).filter {
        let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
        return leadingSpaceCount(lines[$0]) == childIndent && trimmed.hasPrefix("(")
    }
    return childStarts.enumerated().map { offset, start in
        let end = offset + 1 < childStarts.count ? childStarts[offset + 1] : lines.endIndex
        let text = lines[start..<end].joined(separator: "\n")
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let kindEnd = first.firstIndex(where: { $0 == " " || $0 == ")" }) ?? first.endIndex
        return CompilerASTStatement(kind: String(first[..<kindEnd]), text: text)
    }
}

private func compilerDirectBraceCount(_ statement: CompilerASTStatement) -> Int {
    let lines = statement.text.components(separatedBy: "\n")
    guard let first = lines.first else { return 0 }
    let rootIndent = leadingSpaceCount(first)
    return lines.dropFirst().filter {
        leadingSpaceCount($0) == rootIndent + 2
            && $0.trimmingCharacters(in: .whitespaces).hasPrefix("(brace_stmt ")
    }.count
}

private func containsDependentCredentialMutation(_ ast: String) -> Bool {
    let directMutationReferences = [
        "name=\"SourceIndex", "field=\"sessionWillMutate\"",
        "name=\"ApiKeys\"", "name=\"DebridKeys\"",
        "name=\"completeRestoredSession\"", "name=\"completeSignOut\"",
        "name=\"establishCredentialOwner\"", "name=\"stopRealtime\"",
        "name=\"startRealtime\""
    ]
    if directMutationReferences.contains(where: ast.contains) { return true }
    if ast.contains("name=\"Keychain\"") && ast.contains("field=\"set\"") { return true }

    guard ast.contains("(assign_expr") else { return false }
    let sessionFields = ["token", "account", "dataKey", "isSignedIn", "lastSyncAt", "appliedAddonOrder"]
    return sessionFields.contains { field in
        ast.contains("name=\"\(field)\"") || ast.contains("field=\"\(field)\"")
    }
}

private func isCertifiedMalformedRestoreCleanup(_ statement: CompilerASTStatement) -> Bool {
    guard statement.kind == "(guard_stmt",
          let bodyRange = statement.text.range(of: "(brace_stmt"),
          !containsDependentCredentialMutation(String(statement.text[..<bodyRange.lowerBound])),
          let body = compilerNestedBodyStatements(statement), body.count == 2 else { return false }
    let delete = body[0]
    let exit = body[1]
    let deleteWithoutCertifiedKeychain = delete.text.replacingOccurrences(
        of: "name=\"Keychain\"",
        with: "name=\"CertifiedMalformedCleanup\"")
    return statement.text.contains("field=\"decode\"")
        && delete.kind == "(sequence_expr"
        && delete.text.contains("name=\"Keychain\"")
        && delete.text.contains("field=\"set\"")
        && delete.text.contains("name=\"kcAccount\"")
        && delete.text.contains("(nil_literal_expr")
        && occurrenceCount(delete.text, "name=\"Keychain\"") == 1
        && occurrenceCount(delete.text, "field=\"set\"") == 1
        && !containsDependentCredentialMutation(deleteWithoutCertifiedKeychain)
        && exit.kind == "(return_stmt"
        && !containsDependentCredentialMutation(exit.text)
}

private func hasReturnOnlyFailureBody(
    _ statement: CompilerASTStatement,
    literal: String
) -> Bool {
    guard let body = compilerNestedBodyStatements(statement), body.count == 1 else { return false }
    return body[0].kind == "(return_stmt"
        && body[0].text.contains(literal)
        && !containsDependentCredentialMutation(body[0].text)
}

private func isExactDeniedContinuation(
    _ statements: ArraySlice<CompilerASTStatement>,
    log: String,
    schedule: String
) -> Bool {
    guard statements.count == 2 else { return false }
    let continuation = Array(statements)
    return continuation[0].kind == "(call_expr"
        && continuation[0].text.contains("name=\"\(log)\"")
        && !containsDependentCredentialMutation(continuation[0].text)
        && continuation[1].kind == "(call_expr"
        && continuation[1].text.contains("name=\"\(schedule)\"")
        && !containsDependentCredentialMutation(continuation[1].text)
}

private func hasNoMutationBeforeAcquisition(
    _ statements: [CompilerASTStatement],
    anchorKind: String,
    acquisitionReference: String,
    allowedPrelude: (CompilerASTStatement) -> Bool = { _ in false }
) -> Int? {
    let anchors = statements.indices.filter {
        statements[$0].kind == anchorKind && statements[$0].text.contains(acquisitionReference)
    }
    guard anchors.count == 1, let anchor = anchors.first,
          let acquisition = statements[anchor].text.range(of: acquisitionReference) else { return nil }
    for statement in statements[..<anchor] {
        if allowedPrelude(statement) { continue }
        if containsDependentCredentialMutation(statement.text) { return nil }
    }
    if containsDependentCredentialMutation(String(statements[anchor].text[..<acquisition.lowerBound])) {
        return nil
    }
    return anchor
}

/// `adopt` persists its candidate only inside the exact owner-acquisition guard. A normal prelude cannot
/// certify a session because it would run outside the registry publication boundary and could leave an
/// uncertain durable value beside an unchanged owner epoch.
private func hasAdoptPersistenceCertification(
    _ statement: CompilerASTStatement
) -> Bool {
    guard statement.kind == "(guard_stmt",
          let acquisition = statement.text.range(of: "name=\"acquireCredentialOwner\"") else {
        return false
    }
    return statement.text.range(
        of: "field=\"persist\"",
        range: acquisition.upperBound..<statement.text.endIndex) != nil
}

private func compilerCredentialBodyGate(_ source: String) -> CompilerBodyGateEvaluation {
    guard let dump = compilerParseDump(source) else {
        return CompilerBodyGateEvaluation(parsed: false, accepted: false)
    }
    guard let binding = compilerStatements(dump, function: "bindCredentialOwner(_:)") ,
          let restore = compilerStatements(dump, function: "restore()"),
          let signOut = compilerStatements(dump, function: "signOut()"),
          let adopt = compilerStatements(dump, function: "adopt(token:account:dataKey:expectedOperation:)") else {
        return CompilerBodyGateEvaluation(parsed: true, accepted: false)
    }

    guard let bindAnchor = hasNoMutationBeforeAcquisition(
        binding,
        anchorKind: "(guard_stmt",
        acquisitionReference: "field=\"tryBind\"") else {
        return CompilerBodyGateEvaluation(parsed: true, accepted: false)
    }
    let bindingAfterAcquire = binding[(bindAnchor + 1)...].map(\.text).joined(separator: "\n")
    guard hasReturnOnlyFailureBody(binding[bindAnchor], literal: "(nil_literal_expr"),
          bindingAfterAcquire.contains("name=\"ApiKeys\""),
          bindingAfterAcquire.contains("name=\"DebridKeys\"") else {
        return CompilerBodyGateEvaluation(parsed: true, accepted: false)
    }

    guard let restoreAnchor = hasNoMutationBeforeAcquisition(
        restore,
        anchorKind: "(if_stmt",
        acquisitionReference: "name=\"bindCredentialOwner\"",
        allowedPrelude: isCertifiedMalformedRestoreCleanup),
          let restoreBody = restore[restoreAnchor].text.range(of: "(brace_stmt"),
          compilerDirectBraceCount(restore[restoreAnchor]) == 1,
          restore[restoreAnchor].text[..<restoreBody.lowerBound].contains("name=\"bindCredentialOwner\""),
          restore[restoreAnchor].text[..<restoreBody.lowerBound].contains("name=\"completeRestoredSession\""),
          isExactDeniedContinuation(
            restore[(restoreAnchor + 1)...],
            log: "logCredentialOwnerAcquisitionDenied",
            schedule: "scheduleRestoreCredentialOwnerRetry") else {
        return CompilerBodyGateEvaluation(parsed: true, accepted: false)
    }

    guard let signOutAnchor = hasNoMutationBeforeAcquisition(
        signOut,
        anchorKind: "(if_stmt",
        acquisitionReference: "name=\"completeSignOut\""),
          let signOutBody = signOut[signOutAnchor].text.range(of: "(brace_stmt"),
          compilerDirectBraceCount(signOut[signOutAnchor]) == 1,
          signOut[signOutAnchor].text[..<signOutBody.lowerBound].contains("name=\"completeSignOut\""),
          hasReturnOnlyFailureBody(signOut[signOutAnchor], literal: "(return_stmt"),
          isExactDeniedContinuation(
            signOut[(signOutAnchor + 1)...],
            log: "logSignOutCompletionDenied",
            schedule: "scheduleSignOutCredentialOwnerRetry") else {
        return CompilerBodyGateEvaluation(parsed: true, accepted: false)
    }

    guard let adoptAnchor = hasNoMutationBeforeAcquisition(
        adopt,
        anchorKind: "(guard_stmt",
        acquisitionReference: "name=\"acquireCredentialOwner\""),
          adopt.indices.contains(adoptAnchor + 1),
          hasReturnOnlyFailureBody(adopt[adoptAnchor], literal: "value=false"),
          hasAdoptPersistenceCertification(adopt[adoptAnchor]),
          adopt[adoptAnchor + 1].kind == "(guard_stmt",
          adopt[adoptAnchor + 1].text.contains("name=\"authOperationGeneration\""),
          adopt[adoptAnchor + 1].text.contains("name=\"adoptedCapture\""),
          adopt[(adoptAnchor + 2)...].contains(where: { containsDependentCredentialMutation($0.text) }) else {
        return CompilerBodyGateEvaluation(parsed: true, accepted: false)
    }

    return CompilerBodyGateEvaluation(parsed: true, accepted: true)
}

private func insertingProductionGateProbe(
    _ line: String,
    in source: String,
    functionStart: String,
    before acquisition: String
) -> String? {
    guard let functionRange = source.range(of: functionStart),
          let acquisitionRange = source.range(
            of: acquisition,
            range: functionRange.upperBound..<source.endIndex) else { return nil }
    var copy = source
    copy.insert(contentsOf: "        \(line)\n", at: acquisitionRange.lowerBound)
    return copy
}

private func replacingProductionGateProbe(
    _ replacement: String,
    in source: String,
    functionStart: String,
    target: String
) -> String? {
    guard let functionRange = source.range(of: functionStart),
          let targetRange = source.range(of: target, range: functionRange.upperBound..<source.endIndex) else {
        return nil
    }
    var copy = source
    copy.replaceSubrange(targetRange, with: replacement)
    return copy
}

private func productionCredentialBodyGateProof(_ source: String) -> ProductionCredentialBodyGateProof {
    let mutation = "SourceIndexLifecycleScope.shared.sessionWillMutate()"
    let bindMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "private func bindCredentialOwner(",
        before: "        guard let capture = credentialAuthority.tryBind(scope) else { return nil }")
    let bindFailureMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "credentialAuthority.tryBind(scope)",
        before: "return nil }")
    let restoreMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "private func restore()",
        before: "        if let boundCapture = bindCredentialOwner(scope)")
    let restoreDenialMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "private func restore()",
        before: "        logCredentialOwnerAcquisitionDenied(\"restore\"")
    let restoreElseMutation = insertingProductionGateProbe(
        "else { \(mutation) }",
        in: source,
        functionStart: "private func restore()",
        before: "        logCredentialOwnerAcquisitionDenied(\"restore\"")
    let signOutMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "func signOut()",
        before: "        if completeSignOut(fence: fence)")
    let signOutDenialMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "func signOut()",
        before: "        logSignOutCompletionDenied(attempt: 1)")
    let signOutElseMutation = insertingProductionGateProbe(
        "else { \(mutation) }",
        in: source,
        functionStart: "func signOut()",
        before: "        logSignOutCompletionDenied(attempt: 1)")
    let adoptMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "private func adopt(",
        before: "        guard let adoptedCapture = await acquireCredentialOwner(")
    let adoptFailureMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "guard let adoptedCapture = await acquireCredentialOwner(",
        before: "return false }")
    let malformedCleanupMutation = insertingProductionGateProbe(
        mutation,
        in: source,
        functionStart: "guard let data = persisted.data(using: .utf8)",
        before: "_ = Keychain.set(nil, for: kcAccount)")
    let malformedCleanupSessionMutation = replacingProductionGateProbe(
        "_ = { token = nil; return Keychain.set(nil, for: kcAccount) }()",
        in: source,
        functionStart: "guard let data = persisted.data(using: .utf8)",
        target: "_ = Keychain.set(nil, for: kcAccount)")

    var harmlessPrelude = source
    let harmlessInsertions = [
        ("guard !persisted.isEmpty else { return }", "private func restore()",
         "        if let boundCapture = bindCredentialOwner(scope)"),
        ("let validatedFenceGeneration = fence.generation", "func signOut()",
         "        if completeSignOut(fence: fence)"),
        ("guard !token.isEmpty else { return false }", "private func adopt(",
         "        guard let adoptedCapture = await acquireCredentialOwner(")
    ]
    var harmlessProjectionValid = true
    for insertion in harmlessInsertions {
        guard let next = insertingProductionGateProbe(
            insertion.0,
            in: harmlessPrelude,
            functionStart: insertion.1,
            before: insertion.2) else {
            harmlessProjectionValid = false
            break
        }
        harmlessPrelude = next
    }

    let production = compilerCredentialBodyGate(source)
    let bindNegative = bindMutation.map(compilerCredentialBodyGate)
    let bindFailureNegative = bindFailureMutation.map(compilerCredentialBodyGate)
    let restoreNegative = restoreMutation.map(compilerCredentialBodyGate)
    let restoreDenialNegative = restoreDenialMutation.map(compilerCredentialBodyGate)
    let restoreElseNegative = restoreElseMutation.map(compilerCredentialBodyGate)
    let signOutNegative = signOutMutation.map(compilerCredentialBodyGate)
    let signOutDenialNegative = signOutDenialMutation.map(compilerCredentialBodyGate)
    let signOutElseNegative = signOutElseMutation.map(compilerCredentialBodyGate)
    let adoptNegative = adoptMutation.map(compilerCredentialBodyGate)
    let adoptFailureNegative = adoptFailureMutation.map(compilerCredentialBodyGate)
    let malformedCleanupNegative = malformedCleanupMutation.map(compilerCredentialBodyGate)
    let malformedCleanupSessionNegative = malformedCleanupSessionMutation.map(compilerCredentialBodyGate)
    let harmless = harmlessProjectionValid ? compilerCredentialBodyGate(harmlessPrelude) : nil
    return ProductionCredentialBodyGateProof(
        productionAccepted: production.parsed && production.accepted,
        bindMutationRejected: bindNegative?.parsed == true && bindNegative?.accepted == false,
        bindFailureMutationRejected: bindFailureNegative?.parsed == true
            && bindFailureNegative?.accepted == false,
        restoreMutationRejected: restoreNegative?.parsed == true && restoreNegative?.accepted == false,
        restoreDenialMutationRejected: restoreDenialNegative?.parsed == true
            && restoreDenialNegative?.accepted == false,
        restoreElseMutationRejected: restoreElseNegative?.parsed == true
            && restoreElseNegative?.accepted == false,
        signOutMutationRejected: signOutNegative?.parsed == true && signOutNegative?.accepted == false,
        signOutDenialMutationRejected: signOutDenialNegative?.parsed == true
            && signOutDenialNegative?.accepted == false,
        signOutElseMutationRejected: signOutElseNegative?.parsed == true
            && signOutElseNegative?.accepted == false,
        adoptMutationRejected: adoptNegative?.parsed == true && adoptNegative?.accepted == false,
        adoptFailureMutationRejected: adoptFailureNegative?.parsed == true
            && adoptFailureNegative?.accepted == false,
        malformedCleanupMutationRejected: malformedCleanupNegative?.parsed == true
            && malformedCleanupNegative?.accepted == false,
        malformedCleanupSessionMutationRejected: malformedCleanupSessionNegative?.parsed == true
            && malformedCleanupSessionNegative?.accepted == false,
        harmlessPreludeAccepted: harmless?.parsed == true && harmless?.accepted == true)
}

private func runtimeRestoreSourceContract(_ syncManager: String) -> Bool {
    let restore = sourceRegion(syncManager, from: "private func restore()", to: "func signOut()")
    let establishment = sourceRegion(
        syncManager,
        from: "private func establishCredentialOwner(",
        to: "private func persist()")
    return occursInOrder(restore, [
        "switch Keychain.confirmedString(kcAccount)",
        "case .failure:",
        "return",
        "case .missing:",
        "return",
        "case let .value(value):",
        "persisted = value",
        "guard let data = persisted.data(using: .utf8)",
        "_ = Keychain.set(nil, for: kcAccount)",
        "let intent = RestoredSessionIntent(persisted: p, dataKey: dk, scope: scope)",
        "let fence = currentCredentialOwnerIntent()",
        "if let boundCapture = bindCredentialOwner(scope)",
        "completeRestoredSession(intent, capture: boundCapture, fence: fence)",
        "logCredentialOwnerAcquisitionDenied(\"restore\", attempt: 1)",
        "scheduleRestoreCredentialOwnerRetry(intent, fence: fence, startingAt: 2)"
    ])
        && !restore.contains("Keychain.string(kcAccount)")
        && !restore.contains("Keychain.durableString(kcAccount)")
        && occursInOrder(establishment, [
            "credentialAuthority.establishAuthenticatedOwner(capture)",
            "ApiKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)"
        ])
}

private func credentialCompositionSourceContract(_ syncManager: String) -> Bool {
    let coordinator = sourceRegion(
        syncManager,
        from: "enum CredentialRetryCoordinator",
        to: "#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE")
    let binding = sourceRegion(
        syncManager,
        from: "private func bindCredentialOwner(",
        to: "private func providerClaimSucceeded(")
    let providerMigration = sourceRegion(
        syncManager,
        from: "private func providerClaimSucceeded(",
        to: "private func establishCredentialOwner(")
    let establishment = sourceRegion(
        syncManager,
        from: "private func establishCredentialOwner(",
        to: "private func persist()")

    let optionalAcquirePrecedesEveryDependentMutation = binding.contains(
        "private func bindCredentialOwner(_ scope: CredentialScope) -> CredentialScopeRegistry.Capture?")
        && occursInOrder(binding, [
            "guard let capture = credentialAuthority.tryBind(scope) else { return nil }",
            "cancelProviderLegacyMigration(except: capture)",
            "ApiKeys.shared.bind(owner: scope)",
            "DebridKeys.shared.bind(owner: scope)",
            "return capture"
        ])
        && !binding.contains("credentialAuthority.bind(scope)")

    let providerFinalizationIsEstablishedAndFenced = occursInOrder(establishment, [
        "credentialAuthority.establishAuthenticatedOwner(capture)",
        "ApiKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)",
        "DebridKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)",
        "scheduleProviderLegacyMigration(ownerCapture: established)"
    ])
        && providerMigration.contains("CredentialRetryCoordinator.finalizeProviders(")
        && providerMigration.contains("credentialAuthority.isMigrationEligible(capture)")
        && occursInOrder(providerMigration, [
            "TraktTokenSlots.claimLegacyGlobal(owner: capture.scope, capture: capture)",
            "await TraktAuth.shared.finalizeLegacyMigration(ownerCapture: capture)",
            "SIMKLTokenSlots.claimLegacyGlobal(owner: capture.scope, capture: capture)",
            "await SIMKLAuth.shared.finalizeLegacyMigration(ownerCapture: capture)"
        ])
        && !providerMigration.contains("providerClaimsSucceeded")
        && coordinator.contains("if !firstCompleted")
        && coordinator.contains("if !secondCompleted")
        && coordinator.contains("firstCompleted = finalized")
        && coordinator.contains("secondCompleted = finalized")
        && coordinator.contains("guard !Task.isCancelled, isCurrent() else")
        && coordinator.contains("guard attempt < maximumAttempts, await sleepBeforeRetry() else")
        && providerMigration.contains("waitForProviderLegacyMigrationRetry()")
        && providerMigration.contains("providerLegacyMigrationTask?.cancel()")
        && providerMigration.contains("providerLegacyMigrationCapture == capture")
        && occurrenceCount(syncManager, "TraktAuth.shared.finalizeLegacyMigration(ownerCapture: capture)") == 1
        && occurrenceCount(syncManager, "SIMKLAuth.shared.finalizeLegacyMigration(ownerCapture: capture)") == 1
        && !providerMigration.contains("_ = await TraktAuth.shared.finalizeLegacyMigration")
        && !providerMigration.contains("_ = await SIMKLAuth.shared.finalizeLegacyMigration")

    return optionalAcquirePrecedesEveryDependentMutation
        && providerFinalizationIsEstablishedAndFenced
}

private func credentialOwnerRetrySourceContract(_ syncManager: String) -> Bool {
    let coordinator = sourceRegion(
        syncManager,
        from: "enum CredentialRetryCoordinator",
        to: "#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE")
    let retryCore = sourceRegion(
        syncManager,
        from: "private func cancelCredentialOwnerRetry()",
        to: "private func bindCredentialOwner(")
    let transitionHelpers = sourceRegion(
        syncManager,
        from: "private struct RestoredSessionIntent",
        to: "private func providerClaimSucceeded(")
    let restore = sourceRegion(syncManager, from: "private func restore()", to: "func signOut()")
    let signOut = sourceRegion(syncManager, from: "func signOut()", to: "// MARK: - HTTP")
    let adopt = sourceRegion(syncManager, from: "private func adopt(", to: "enum AuthResult")

    let boundedLoggedRetry = syncManager.contains("private let credentialOwnerMaximumAttempts = 3")
        && retryCore.contains("CredentialRetryCoordinator.acquireOwner(")
        && retryCore.contains("attempts: firstAttempt...credentialOwnerMaximumAttempts")
        && coordinator.contains("for attempt in attempts")
        && coordinator.contains("guard !Task.isCancelled, isCurrent() else")
        && coordinator.contains("if let value = tryAcquire(attempt) { return .acquired(value) }")
        && retryCore.contains("logCredentialOwnerAcquisitionDenied(operation, attempt: attempt)")
        && retryCore.contains("logCredentialOwnerAcquisitionExhausted(operation)")
        && retryCore.contains("waitForCredentialOwnerRetry(operation: operation, fence: fence)")
        && retryCore.contains("credentialOwnerRetryTask?.cancel()")
        && coordinator.contains("static func launch<Success: Sendable>")
        && !coordinator.contains("\n        while ")

    let restoreRetainsAndRetriesExactPayload = transitionHelpers.contains(
        "private struct RestoredSessionIntent")
        && transitionHelpers.contains("let persisted: Persisted")
        && transitionHelpers.contains("let dataKey: Data")
        && transitionHelpers.contains("let scope: CredentialScope")
        && syncManager.contains("private var credentialOwnerRetryTask: Task<Void, Never>?")
        && occursInOrder(restore, [
            "let intent = RestoredSessionIntent(persisted: p, dataKey: dk, scope: scope)",
            "let fence = currentCredentialOwnerIntent()",
            "if let boundCapture = bindCredentialOwner(scope)",
            "completeRestoredSession(intent, capture: boundCapture, fence: fence)",
            "logCredentialOwnerAcquisitionDenied(\"restore\", attempt: 1)",
            "scheduleRestoreCredentialOwnerRetry(intent, fence: fence, startingAt: 2)"
        ])
        && occursInOrder(transitionHelpers, [
            "private func scheduleRestoreCredentialOwnerRetry(",
            "CredentialRetryCoordinator.launch { [weak self] in",
            "await self.acquireCredentialOwner(",
            "scope: intent.scope",
            "operation: \"restore\"",
            "completeRestoredSession(intent, capture: capture, fence: fence)"
        ])

    let signOutRetriesCapturedGeneration = occursInOrder(signOut, [
        "let fence = beginCredentialOwnerIntent()",
        "if completeSignOut(fence: fence)",
        "logSignOutCompletionDenied(attempt: 1)",
        "scheduleSignOutCredentialOwnerRetry(fence: fence, startingAt: 2)"
    ])
        && occursInOrder(transitionHelpers, [
            "private func scheduleSignOutCredentialOwnerRetry(",
            "CredentialRetryCoordinator.acquireOwner(",
            "self?.isCurrent(fence) == true",
            "self.completeSignOut(fence: fence) ? true : nil",
            "self?.logSignOutCompletionDenied(attempt: attempt)",
            "self?.logSignOutCompletionExhausted()",
            "self.waitForSignOutCompletionRetry(fence: fence)"
        ])

    let adoptAwaitsExactIntent = adopt.contains(") async -> Bool")
        && occursInOrder(adopt, [
            "let operation = expectedOperation ?? currentCredentialOwnerIntent()",
            "guard let adoptedCapture = await acquireCredentialOwner(",
            "scope: scope",
            "operation: \"adopt\"",
            "fence: operation",
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            "self.token = token",
            "self.dataKey = dataKey",
            "self.isSignedIn = true"
        ])
        && occurrenceCount(syncManager, "guard await adopt(token:") == 4

    let successfulApplyIsFenced = transitionHelpers.contains(
        "guard fence.generation == authOperationGeneration,")
        && transitionHelpers.contains("isCurrent(capture) else { return false }")
        && transitionHelpers.contains("isPreSignOutCurrent: { self.isCurrent(fence) }")
        && occurrenceCount(transitionHelpers, "SourceIndexLifecycleScope.shared.sessionWillMutate()") == 2
        && retryCore.contains("authOperationGeneration &+= 1")
        && retryCore.contains("cancelCredentialOwnerRetry()")

    return boundedLoggedRetry
        && restoreRetainsAndRetriesExactPayload
        && signOutRetriesCapturedGeneration
        && adoptAwaitsExactIntent
        && successfulApplyIsFenced
}

/// Signing out is a durable credential mutation, not merely a UI transition. The persisted session must be
/// confirmed absent before any live state, realtime channel, source index, or published flag can move to the
/// signed-out projection. A failed deletion remains inside the same bounded generation-fenced retry task.
private func signOutDurabilitySourceContract(_ syncManager: String) -> Bool {
    let coordinator = sourceRegion(
        syncManager,
        from: "enum CredentialSignOutCoordinator",
        to: "enum CredentialRetryCoordinator")
    let completion = sourceRegion(
        syncManager,
        from: "private func completeSignOut(",
        to: "private func scheduleSignOutCredentialOwnerRetry(")
    let retry = sourceRegion(
        syncManager,
        from: "private func scheduleSignOutCredentialOwnerRetry(",
        to: "private func providerClaimSucceeded(")
    let signOut = sourceRegion(syncManager, from: "func signOut()", to: "// MARK: - HTTP")

    return occursInOrder(coordinator, [
        "guard isPreSignOutCurrent() else { return false }",
        "guard deletePersistedSession() == .success else { return false }",
        "guard isPreSignOutCurrent() else { return false }",
        "guard bindSignedOutOwner() else { return false }",
        "publishSignedOutState()",
        "return true"
    ])
        && occursInOrder(completion, [
        "CredentialSignOutCoordinator.complete(",
        "isPreSignOutCurrent:",
        "self.isCurrent(fence)",
        "deletePersistedSession:",
        "Keychain.set(nil, for: self.kcAccount)",
        "bindSignedOutOwner:",
        "self.bindCredentialOwner(.signedOutDevice)",
        "publishSignedOutState:",
        "SourceIndexLifecycleScope.shared.sessionWillMutate()",
        "stopRealtime()",
        "token = nil",
        "account = nil",
        "dataKey = nil",
        "isSignedIn = false",
        "lastSyncAt = nil",
        "Self.appliedAddonOrder = []",
    ])
        && occurrenceCount(completion, "Keychain.set(nil, for: self.kcAccount)") == 1
        && !completion.contains("_ = Keychain.set(nil, for:")
        && retry.contains("CredentialRetryCoordinator.acquireOwner(")
        && retry.contains("attempts: firstAttempt...self.credentialOwnerMaximumAttempts")
        && occursInOrder(retry, [
            "self?.isCurrent(fence) == true",
            "return self.completeSignOut(fence: fence) ? true : nil",
            "self?.logSignOutCompletionDenied(attempt: attempt)",
            "self?.logSignOutCompletionExhausted()"
        ])
        && occursInOrder(signOut, [
            "let fence = beginCredentialOwnerIntent()",
            "if completeSignOut(fence: fence)",
            "return",
            "logSignOutCompletionDenied(attempt: 1)",
            "scheduleSignOutCredentialOwnerRetry(fence: fence, startingAt: 2)"
        ])
}

/// `request` is the one current VortX API helper for auth, QR, bearer, and backup calls. It must delegate
/// every one of those requests to the shared bearer transport, retaining its exact host, no-redirect,
/// no-cookie, no-cache, and bounded-response guarantees before any JSON reaches the manager.
private func authenticatedVortXRequestSourceContract(_ syncManager: String) -> Bool {
    let request = sourceRegion(
        syncManager,
        from: "private func request(",
        to: "@discardableResult\n    private func adopt(")

    return occursInOrder(request, [
        "if let credentialCapture, !isCurrent(credentialCapture) { return (0, nil) }",
        "guard let url = URL(string: base + path) else { return (0, nil) }",
        "if let t = bearer ?? (auth ? token : nil)",
        "let maxResponseBytes = path == \"/v1/backup\"",
        "? AuthenticatedHTTPTransport.snapshotResponseLimit",
        ": AuthenticatedHTTPTransport.controlResponseLimit",
        "let response = try await AuthenticatedHTTPTransport.shared.send(",
        "req,",
        "allowedHosts: [\"api.vortx.tv\"]",
        "maxResponseBytes: maxResponseBytes",
        "if let credentialCapture, !isCurrent(credentialCapture) { return (0, nil) }",
        "let json = (try? AuthenticatedHTTPTransport.jsonObject(from: response.data)) as? [String: Any]",
        "return (response.statusCode, json)"
    ])
        && !request.contains("URLSession.shared.data(for:")
        && !request.contains("URLSession.shared")
        && occurrenceCount(syncManager, "AuthenticatedHTTPTransport.snapshotResponseLimit") == 1
        && occurrenceCount(syncManager, "AuthenticatedHTTPTransport.controlResponseLimit") == 1
        && request.contains("catch { return (0, nil) }")
}

/// Interactive adoption may certify a candidate session only while the registry holds its publication
/// boundary. A failed certification keeps the prior owner capture and all live session fields intact.
private func adoptDurabilitySourceContract(
    _ syncManager: String,
    credentialScope: String
) -> Bool {
    let certifyingBind = sourceRegion(
        credentialScope,
        from: "func tryBind(\n        _ newScope: CredentialScope,\n        certifying: @MainActor () -> CredentialMutationResult",
        to: "/// Compatibility surface")
    let acquisition = sourceRegion(
        syncManager,
        from: "private func acquireCredentialOwner(",
        to: "/// Linearize the owner transition")
    let binding = sourceRegion(
        syncManager,
        from: "private func bindCredentialOwner(",
        to: "private struct RestoredSessionIntent")
    let persistence = sourceRegion(
        syncManager,
        from: "private func persist(",
        to: "private func restore()")
    let adopt = sourceRegion(syncManager, from: "private func adopt(", to: "enum AuthResult")

    return occursInOrder(certifyingBind, [
        "CredentialPublicationOutbox.acquireBoundary() == .acquired",
        "defer { CredentialPublicationOutbox.endBoundary() }",
        "guard certifying() == .success else { return nil }",
        "lock.lock()",
        "scope = newScope",
        "generation &+= 1",
        "establishedGeneration = nil"
    ])
        && acquisition.contains("certifying: @escaping @MainActor () -> CredentialMutationResult = { .success }")
        && acquisition.contains("self?.bindCredentialOwner(scope, certifying: certifying)")
        && binding.contains("certifying: @MainActor () -> CredentialMutationResult")
        && binding.contains("credentialAuthority.tryBind(scope, certifying: certifying)")
        && persistence.contains("private func persist(")
        && persistence.contains(") -> CredentialMutationResult")
        && persistence.contains("return Keychain.set(str, for: kcAccount)")
        && !persistence.contains("_ = Keychain.set")
        && occursInOrder(adopt, [
            "let candidateAccount = Account(",
            "guard let adoptedCapture = await acquireCredentialOwner(",
            "scope: scope",
            "operation: \"adopt\"",
            "fence: operation",
            "certifying: {",
            "self.persist(token: token, account: candidateAccount, dataKey: dataKey)",
            "guard operation.generation == authOperationGeneration",
            "guard establishCredentialOwner(adoptedCapture) else { return false }",
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            "self.token = token",
            "self.dataKey = dataKey",
            "self.account = candidateAccount",
            "self.isSignedIn = true"
        ])
        && !adopt.contains("        persist()")
}

/// A pull is not acknowledged until both named provider adoptions have returned under the exact credential
/// capture. Failed provider values are retained per capture and version, so only the failed provider retries.
private func providerAdoptionSettlementSourceContract(_ syncManager: String) -> Bool {
    let declarations = sourceRegion(
        syncManager,
        from: "private struct PendingDebridApply",
        to: "/// Set while syncDown is applying")
    let syncDown = sourceRegion(
        syncManager,
        from: "func syncDown(",
        to: "// MARK: - Account owns everything")
    let providerSection = sourceRegion(
        syncDown,
        from: "// External sync provider tokens",
        to: "// Media servers (lane E):")
    let providerSettlement = sourceRegion(
        syncDown,
        from: "let providerSettlement: CredentialProviderRetryOutcome",
        to: "// OwnerResumeStore changed")
    let beforeProviderSettlement = sourceRegion(
        syncDown,
        from: "pendingProviderApply = providerPlan",
        to: "let providerSettlement: CredentialProviderRetryOutcome")
    let bindTransition = sourceRegion(
        syncManager,
        from: "private func cancelProviderLegacyMigration(",
        to: "private func waitForProviderLegacyMigrationRetry()")
    let versionStamp = "lastSyncedVersion = max(lastSyncedVersion, pulled.version)"

    return declarations.contains("private enum ProviderApplyService")
        && declarations.contains("private enum ProviderApplyValue")
        && declarations.contains("private struct PendingProviderApply")
        && declarations.contains("private var pendingProviderApply: PendingProviderApply?")
        && declarations.contains("private func hasPendingAccountDocApply")
        && syncManager.contains("private let providerRemoteApplyMaximumAttempts = 3")
        && syncManager.contains("private let providerRemoteApplyRetryNanos: UInt64 = 100_000_000")
        && syncManager.contains("private func waitForProviderRemoteApplyRetry(")
        && bindTransition.contains("pendingProviderApply?.capture != capture")
        && bindTransition.contains("pendingProviderApply = nil")
        && occurrenceCount(syncManager, "hasPendingAccountDocApply(for: capture)") >= 16
        && occursInOrder(declarations, [
            "private func providerApplyIntent(",
            "if let pending = pendingProviderApply",
            "pending.capture == capture",
            "pending.version == version",
            "return pending",
            "if let retained = priorValues[.trakt]",
            "if let retained = priorValues[.simkl]",
            "return PendingProviderApply("
        ])
        && !providerSection.contains("Task {")
        && !beforeProviderSettlement.contains(versionStamp)
        && !beforeProviderSettlement.contains("hasAppliedAccountDoc = true")
        && occursInOrder(syncDown, [
            "var providerPlan: PendingProviderApply?",
            "withRemoteApplySuppressed {",
            "providerPlan = providerApplyIntent(",
            "pendingProviderApply = providerPlan",
            "guard isCurrent(capture), pendingDebridServices.isEmpty else { return false }",
            "let providerSettlement: CredentialProviderRetryOutcome",
            "providerSettlement = await CredentialRetryCoordinator.finalizeProviders(",
            "maximumAttempts: providerRemoteApplyMaximumAttempts",
            "return await TraktAuth.shared.adoptTokens(",
            "ownerCapture: pending.capture",
            "return await SIMKLAuth.shared.adoptTokens(",
            "ownerCapture: pending.capture",
            "guard isCurrent(capture), !providerSettlement.superseded else { return false }",
            "if !providerSettlement.completed {",
            "let failedProviderValues = pending.values.filter",
            "pendingProviderApply = PendingProviderApply(",
            "pendingProviderApply = nil",
            versionStamp,
            "hasAppliedAccountDoc = true"
        ])
        && !providerSettlement.contains("Task {")
}

@MainActor
private func ownerIsolation() -> (
    signedOutClosed: Bool,
    bClosedBeforeSet: Bool,
    bRuntimeOwnsOnlyB: Bool,
    bPushOwnsOnlyB: Bool,
    aReloadRestoresA: Bool,
    bReloadRestoresB: Bool
) {
    let accountA = CredentialScope(canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    Keychain.reset()
    let keys = ApiKeys.shared

    _ = CredentialScopeRegistry.shared.bind(accountA)
    keys.bind(owner: accountA)
    keys.tmdb = "A-tmdb"
    keys.mdblist = "A-mdblist"
    keys.fanart = "A-fanart"
    keys.skipdb = "A-skipdb"
    keys.customSkipURL = "https://a.invalid"
    keys.customSkipKey = "A-skip-key"

    _ = CredentialScopeRegistry.shared.bind(.signedOutDevice)
    keys.bind(owner: .signedOutDevice)
    let signedOutClosed = ApiKeys.tmdbKey() == nil
        && ApiKeys.mdblistKey() == nil
        && ApiKeys.fanartKey() == nil
        && ApiKeys.skipDBKey() == nil
        && ApiKeys.customSkipURL() == nil
        && ApiKeys.customSkipKey() == nil

    _ = CredentialScopeRegistry.shared.bind(accountB)
    keys.bind(owner: accountB)
    let bClosedBeforeSet = ApiKeys.tmdbKey() == nil
        && ApiKeys.mdblistKey() == nil
        && ApiKeys.fanartKey() == nil
        && ApiKeys.skipDBKey() == nil
        && ApiKeys.customSkipURL() == nil
        && ApiKeys.customSkipKey() == nil

    keys.tmdb = "B-tmdb"
    keys.mdblist = "B-mdblist"
    keys.fanart = "B-fanart"
    keys.skipdb = "B-skipdb"
    keys.customSkipURL = "https://b.invalid"
    keys.customSkipKey = "B-skip-key"
    let bRuntimeOwnsOnlyB = keys.tmdb == "B-tmdb"
        && keys.mdblist == "B-mdblist"
        && keys.fanart == "B-fanart"
        && keys.skipdb == "B-skipdb"
        && keys.customSkipURL == "https://b.invalid"
        && keys.customSkipKey == "B-skip-key"
    let bPushOwnsOnlyB = ApiKeys.tmdbKey() == "B-tmdb"
        && ApiKeys.mdblistKey() == "B-mdblist"
        && ApiKeys.fanartKey() == "B-fanart"
        && ApiKeys.skipDBKey() == "B-skipdb"
        && ApiKeys.customSkipURL() == "https://b.invalid"
        && ApiKeys.customSkipKey() == "B-skip-key"

    _ = CredentialScopeRegistry.shared.bind(accountA)
    keys.bind(owner: accountA)
    let aReloadRestoresA = keys.tmdb == "A-tmdb"
        && keys.mdblist == "A-mdblist"
        && keys.fanart == "A-fanart"
        && keys.skipdb == "A-skipdb"
        && keys.customSkipURL == "https://a.invalid"
        && keys.customSkipKey == "A-skip-key"

    _ = CredentialScopeRegistry.shared.bind(accountB)
    keys.bind(owner: accountB)
    let bReloadRestoresB = keys.tmdb == "B-tmdb"
        && keys.mdblist == "B-mdblist"
        && keys.fanart == "B-fanart"
        && keys.skipdb == "B-skipdb"
        && keys.customSkipURL == "https://b.invalid"
        && keys.customSkipKey == "B-skip-key"

    return (signedOutClosed, bClosedBeforeSet, bRuntimeOwnsOnlyB, bPushOwnsOnlyB,
            aReloadRestoresA, bReloadRestoresB)
}

@MainActor
private func stalePullCannotMutateB() -> Bool {
    let accountA = CredentialScope(canonicalRemoteAccountID: "12121212-1212-1212-1212-121212121212")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "34343434-3434-3434-3434-343434343434")!
    Keychain.reset()
    let keys = ApiKeys.shared
    let staleCapture = CredentialScopeRegistry.shared.bind(accountA)
    keys.bind(owner: accountA)
    keys.tmdb = "A-pull"
    keys.mdblist = "A-pull-mdblist"

    _ = CredentialScopeRegistry.shared.bind(accountB)
    keys.bind(owner: accountB)
    keys.tmdb = "B-runtime"
    keys.mdblist = "B-runtime-mdblist"
    let staleRejected = !CredentialScopeRegistry.shared.isCurrent(staleCapture)
    if CredentialScopeRegistry.shared.isCurrent(staleCapture) {
        keys.tmdb = "stale-A-must-not-apply"
        keys.mdblist = "stale-A-mdblist-must-not-apply"
    }
    return staleRejected
        && keys.tmdb == "B-runtime"
        && keys.mdblist == "B-runtime-mdblist"
        && ApiKeys.tmdbKey() == "B-runtime"
        && ApiKeys.mdblistKey() == "B-runtime-mdblist"
}

@MainActor
private func authenticatedLegacyMigration() -> (signedOutClosed: Bool, unprovenClosed: Bool, migrated: Bool, exactOnce: Bool) {
    let account = CredentialScope(canonicalRemoteAccountID: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    Keychain.reset()
    for (slot, value) in [
        (ApiKeySlots.legacyTMDB, "legacy-tmdb"),
        (ApiKeySlots.legacyMDBList, "legacy-mdblist"),
        (ApiKeySlots.legacyFanart, "legacy-fanart"),
        (ApiKeySlots.legacySkipDB, "legacy-skipdb"),
        (ApiKeySlots.legacyCustomSkipURL, "https://legacy.invalid"),
        (ApiKeySlots.legacyCustomSkipKey, "legacy-skip-key")
    ] { Keychain.set(value, for: slot) }

    let keys = ApiKeys.shared
    let signedOutCapture = CredentialScopeRegistry.shared.bind(.signedOutDevice)
    keys.bind(owner: .signedOutDevice)
    let signedOutDenied = !keys.migrateLegacyIfEligible(owner: .signedOutDevice, capture: signedOutCapture)
    let signedOutSourceStillPresent = Keychain.string(ApiKeySlots.legacyTMDB) == "legacy-tmdb"
    let signedOutClosed = signedOutDenied && signedOutSourceStillPresent

    let capture = CredentialScopeRegistry.shared.bind(account)
    keys.bind(owner: account)
    let unproven = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let sourceStillPresent = Keychain.string(ApiKeySlots.legacyTMDB) == "legacy-tmdb"
    let unprovenClosed = unproven && sourceStillPresent

    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
    let migrated = keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let destinationValues = [
        ApiKeySlots.tmdb(account), ApiKeySlots.mdblist(account), ApiKeySlots.fanart(account),
        ApiKeySlots.skipDB(account), ApiKeySlots.customSkipURL(account), ApiKeySlots.customSkipKey(account)
    ].compactMap(Keychain.string)
    let migratedValues = destinationValues == [
        "legacy-tmdb", "legacy-mdblist", "legacy-fanart", "legacy-skipdb",
        "https://legacy.invalid", "legacy-skip-key"
    ]
    let sourceDeleted = [
        ApiKeySlots.legacyTMDB, ApiKeySlots.legacyMDBList, ApiKeySlots.legacyFanart,
        ApiKeySlots.legacySkipDB, ApiKeySlots.legacyCustomSkipURL, ApiKeySlots.legacyCustomSkipKey
    ].allSatisfy { Keychain.string($0) == nil }
    let repeated = keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let exactOnce = repeated && migratedValues && sourceDeleted
    return (signedOutClosed, unprovenClosed, migrated && migratedValues, exactOnce)
}

@MainActor
private func migrationFailureRetries() -> (destinationRetry: Bool, sourceRetry: Bool) {
    let account = CredentialScope(canonicalRemoteAccountID: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
    Keychain.reset()
    let capture = CredentialScopeRegistry.shared.bind(account)
    let keys = ApiKeys.shared
    keys.bind(owner: account)
    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)

    Keychain.set("destination-retry", for: ApiKeySlots.legacyTMDB)
    Keychain.failNextWrite(for: ApiKeySlots.tmdb(account))
    let destinationFailed = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let destinationRetained = destinationFailed
        && Keychain.string(ApiKeySlots.legacyTMDB) == "destination-retry"
        && Keychain.string(ApiKeySlots.tmdb(account)) == nil
    let destinationRepaired = Keychain.set(
        "destination-retry", for: ApiKeySlots.tmdb(account)) == .success
    let destinationRetry = destinationRetained
        && destinationRepaired
        && keys.migrateLegacyIfEligible(owner: account, capture: capture)
        && Keychain.string(ApiKeySlots.tmdb(account)) == "destination-retry"
        && Keychain.string(ApiKeySlots.legacyTMDB) == nil

    Keychain.reset()
    Keychain.set("source-retry", for: ApiKeySlots.legacyTMDB)
    Keychain.failNextDelete(for: ApiKeySlots.legacyTMDB)
    let sourceFailed = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let sourceRetry = sourceFailed
        && Keychain.string(ApiKeySlots.tmdb(account)) == "source-retry"
        && Keychain.string(ApiKeySlots.legacyTMDB) == "source-retry"
        && keys.migrateLegacyIfEligible(owner: account, capture: capture)
        && Keychain.string(ApiKeySlots.legacyTMDB) == nil
    return (destinationRetry, sourceRetry)
}

@MainActor
private func migrationCertificationFailures() -> (
    postPersistSourceRetained: Bool,
    postPersistRetry: Bool,
    sourceReadFailureRetained: Bool,
    sourceReadRetry: Bool
) {
    let account = CredentialScope(canonicalRemoteAccountID: "abababab-abab-abab-abab-abababababab")!
    let keys = ApiKeys.shared
    let capture = CredentialScopeRegistry.shared.bind(account)
    keys.bind(owner: account)
    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)

    Keychain.reset()
    let postPersistSource = ApiKeySlots.legacyTMDB
    let postPersistDestination = ApiKeySlots.tmdb(account)
    Keychain.set("post-persist-source", for: postPersistSource)
    Keychain.failAfterPersist(for: postPersistDestination)
    let firstPostPersist = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let postPersistSourceRetained = firstPostPersist
        && Keychain.durableString(postPersistSource) == .value("post-persist-source")
        && Keychain.confirmedString(postPersistDestination) == .failure

    Keychain.repairAfterPersist(for: postPersistDestination)
    _ = Keychain.set("post-persist-source", for: postPersistDestination)
    let postPersistRetry = keys.migrateLegacyIfEligible(owner: account, capture: capture)
        && Keychain.durableString(postPersistSource) == .missing
        && Keychain.confirmedString(postPersistDestination) == .value("post-persist-source")

    Keychain.reset()
    let sourceReadFailureSource = ApiKeySlots.legacyTMDB
    let sourceReadFailureDestination = ApiKeySlots.tmdb(account)
    Keychain.set("source-read-failure", for: sourceReadFailureSource)
    Keychain.failNextRead(for: sourceReadFailureSource)
    let firstSourceReadFailure = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let sourceReadFailureRetained = firstSourceReadFailure
        && Keychain.durableString(sourceReadFailureSource) == .value("source-read-failure")
        && Keychain.durableString(sourceReadFailureDestination) == .missing

    let sourceReadRetry = keys.migrateLegacyIfEligible(owner: account, capture: capture)
        && Keychain.durableString(sourceReadFailureSource) == .missing
        && Keychain.confirmedString(sourceReadFailureDestination) == .value("source-read-failure")
    return (postPersistSourceRetained, postPersistRetry,
            sourceReadFailureRetained, sourceReadRetry)
}

@MainActor
private func migrationDestinationReadFailures() -> (
    transientNoMutation: Bool,
    transientRetry: Bool,
    invalidatedNoMutation: Bool
) {
    let account = CredentialScope(canonicalRemoteAccountID: "56565656-5656-5656-5656-565656565656")!
    let keys = ApiKeys.shared
    let capture = CredentialScopeRegistry.shared.bind(account)
    keys.bind(owner: account)
    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)

    let transientSource = ApiKeySlots.legacyTMDB
    let transientDestination = ApiKeySlots.tmdb(account)
    Keychain.reset()
    Keychain.set("transient-existing", for: transientSource)
    Keychain.set("transient-existing", for: transientDestination)
    Keychain.failNextRead(for: transientDestination)
    let transientDestinationWrites = Keychain.writeCount(for: transientDestination)
    let transientSourceDeletes = Keychain.deleteCount(for: transientSource)
    let transientFirst = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let transientNoMutation = transientFirst
        && Keychain.writeCount(for: transientDestination) == transientDestinationWrites
        && Keychain.deleteCount(for: transientSource) == transientSourceDeletes
        && Keychain.durableString(transientSource) == .value("transient-existing")
    let transientRetry = keys.migrateLegacyIfEligible(owner: account, capture: capture)
        && Keychain.durableString(transientSource) == .missing
        && Keychain.confirmedString(transientDestination) == .value("transient-existing")

    let invalidatedSource = ApiKeySlots.legacyTMDB
    let invalidatedDestination = ApiKeySlots.tmdb(account)
    Keychain.reset()
    Keychain.set("invalidated-existing", for: invalidatedSource)
    Keychain.set("invalidated-existing", for: invalidatedDestination)
    Keychain.failAfterPersist(for: invalidatedDestination)
    _ = Keychain.set("invalidated-existing", for: invalidatedDestination)
    let invalidatedDestinationWrites = Keychain.writeCount(for: invalidatedDestination)
    let invalidatedSourceDeletes = Keychain.deleteCount(for: invalidatedSource)
    let invalidatedFirst = !keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let invalidatedNoMutation = invalidatedFirst
        && Keychain.writeCount(for: invalidatedDestination) == invalidatedDestinationWrites
        && Keychain.deleteCount(for: invalidatedSource) == invalidatedSourceDeletes
        && Keychain.durableString(invalidatedSource) == .value("invalidated-existing")
        && Keychain.confirmedString(invalidatedDestination) == .failure
    return (transientNoMutation, transientRetry, invalidatedNoMutation)
}

@MainActor
private func independentLegacyClaims() -> (singleSlotMigrated: Bool, markersIndependent: Bool, interpolationExact: Bool) {
    let account = CredentialScope(canonicalRemoteAccountID: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
    Keychain.reset()
    Keychain.set("single-slot", for: ApiKeySlots.legacyTMDB)
    let capture = CredentialScopeRegistry.shared.bind(account)
    let keys = ApiKeys.shared
    keys.bind(owner: account)
    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
    let migrated = keys.migrateLegacyIfEligible(owner: account, capture: capture)
    let singleSlotMigrated = migrated
        && Keychain.string(ApiKeySlots.tmdb(account)) == "single-slot"
        && Keychain.string(ApiKeySlots.legacyTMDB) == nil
        && Keychain.string(ApiKeySlots.mdblist(account)) == nil
    let legacySlots = [
        ApiKeySlots.legacyTMDB, ApiKeySlots.legacyMDBList, ApiKeySlots.legacyFanart,
        ApiKeySlots.legacySkipDB, ApiKeySlots.legacyCustomSkipURL, ApiKeySlots.legacyCustomSkipKey
    ]
    let markersIndependent = Set(legacySlots.map(ApiKeySlots.migrationMarker)).count == legacySlots.count
    let sourceText = contracts().apiKeys
    let interpolationExact = sourceText.contains("provenanceTag: \"api-key-\\(slot.source)\"")
    return (singleSlotMigrated, markersIndependent, interpolationExact)
}

@MainActor
private func initializationAndBindIsNonRecursive() -> Bool {
    let account = CredentialScope(canonicalRemoteAccountID: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
    Keychain.reset()
    let capture = CredentialScopeRegistry.shared.bind(account)
    let keys = ApiKeys.shared
    keys.bind(owner: account)
    let accountCleared = keys.tmdb.isEmpty && keys.customSkipKey.isEmpty
    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
    _ = CredentialScopeRegistry.shared.bind(.signedOutDevice)
    keys.bind(owner: .signedOutDevice)
    return accountCleared && keys.tmdb.isEmpty && keys.customSkipURL.isEmpty
}

@MainActor
private func confirmedReadRetryPreservesPrior() -> (
    transientRetry: Bool,
    persistentFailureClosed: Bool,
    runtimePreserved: Bool
) {
    let account = CredentialScope(canonicalRemoteAccountID: "abababab-abab-abab-abab-abababababab")!
    Keychain.reset()
    let keys = ApiKeys.shared
    _ = CredentialScopeRegistry.shared.bind(account)
    keys.bind(owner: account)
    keys.tmdb = "prior-runtime"

    let slot = ApiKeySlots.tmdb(account)
    let beforeTransient = Keychain.readCount(for: slot)
    Keychain.failNextRead(for: slot)
    let transientValue = ApiKeys.tmdbKey()
    let transientRetry = transientValue == "prior-runtime"
        && Keychain.readCount(for: slot) == beforeTransient + 2

    Keychain.failReads(for: slot)
    let beforePersistent = Keychain.readCount(for: slot)
    let persistentValue = ApiKeys.tmdbKey()
    let persistentFailureClosed = persistentValue == nil
        && Keychain.readCount(for: slot) == beforePersistent + 2
    let runtimePreserved = keys.tmdb == "prior-runtime"
    return (transientRetry, persistentFailureClosed, runtimePreserved)
}

@MainActor
private func failedWriteRetriesAndPreservesPrior() -> (
    transientRetry: Bool,
    persistentFailureClosed: Bool,
    syncOnlyAfterConfirmation: Bool
) {
    let account = CredentialScope(canonicalRemoteAccountID: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
    Keychain.reset()
    VortXSyncManager.resetSyncRequests()
    let keys = ApiKeys.shared
    _ = CredentialScopeRegistry.shared.bind(account)
    keys.bind(owner: account)
    keys.tmdb = "old-value"
    let slot = ApiKeySlots.tmdb(account)

    let beforeTransientSync = VortXSyncManager.syncRequests
    Keychain.failNextWrite(for: slot)
    keys.tmdb = "retry-value"
    let transientRetry = keys.tmdb == "retry-value"
        && Keychain.durableString(slot) == .value("retry-value")
        && Keychain.totalWriteCount == 3
        && VortXSyncManager.syncRequests == beforeTransientSync + 1

    let beforePersistentSync = VortXSyncManager.syncRequests
    Keychain.failWrites(for: slot)
    keys.tmdb = "rejected-value"
    let persistentFailureClosed = keys.tmdb == "retry-value"
        && Keychain.durableString(slot) == .value("retry-value")
        && Keychain.totalWriteCount == 5
    let syncOnlyAfterConfirmation = VortXSyncManager.syncRequests == beforePersistentSync
    return (transientRetry, persistentFailureClosed, syncOnlyAfterConfirmation)
}

@main
struct ApiKeysCredentialSecurityTests {
    @MainActor
    static func main() async {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        let isolation = ownerIsolation()
        expect(isolation.signedOutClosed, "signed-out runtime and static readers never expose account A")
        expect(isolation.bClosedBeforeSet, "account B starts without account A's runtime or push credentials")
        expect(isolation.bRuntimeOwnsOnlyB, "account B runtime reload contains only B's six values")
        expect(isolation.bPushOwnsOnlyB, "account B push readers contain only B's six values")
        expect(isolation.aReloadRestoresA, "account A retains its own values across sign-out and account B")
        expect(isolation.bReloadRestoresB, "account B reload restores its own values after account A")
        expect(stalePullCannotMutateB(), "a stale account A pull cannot mutate account B")

        let migration = authenticatedLegacyMigration()
        expect(migration.signedOutClosed, "signed-out state cannot claim ApiKeys legacy slots")
        expect(migration.unprovenClosed, "an unproven account cannot consume legacy ApiKeys slots")
        expect(migration.migrated, "an authenticated owner migrates all six legacy ApiKeys slots")
        expect(migration.exactOnce, "ApiKeys legacy migration is destination-first and exact-once")

        let retries = migrationFailureRetries()
        expect(retries.destinationRetry, "ApiKeys migration retries after destination write failure")
        expect(retries.sourceRetry, "ApiKeys migration retries after source delete failure")

        let certifiedMigration = migrationCertificationFailures()
        expect(certifiedMigration.postPersistSourceRetained,
               "post-persist destination failure retains the legacy source")
        expect(certifiedMigration.postPersistRetry,
               "post-persist destination failure retries to a certified destination")
        expect(certifiedMigration.sourceReadFailureRetained,
               "source read failure is retryable and retains the legacy source")
        expect(certifiedMigration.sourceReadRetry,
               "source read failure retries migration successfully")

        let destinationReadFailures = migrationDestinationReadFailures()
        expect(destinationReadFailures.transientNoMutation,
               "transient existing-destination read failure performs no claim write or source delete")
        expect(destinationReadFailures.transientRetry,
               "transient destination read failure retries after certification becomes readable")
        expect(destinationReadFailures.invalidatedNoMutation,
               "invalidated existing-destination read failure performs no claim write or source delete")

        let independent = independentLegacyClaims()
        expect(independent.singleSlotMigrated, "each ApiKeys legacy slot claims independently")
        expect(independent.markersIndependent, "each ApiKeys legacy slot has an independent claim marker")
        expect(independent.interpolationExact, "ApiKeys migration provenance records the concrete source slot")
        expect(initializationAndBindIsNonRecursive(), "ApiKeys initialization and bind reload without didSet recursion")

        let readDurability = confirmedReadRetryPreservesPrior()
        expect(readDurability.transientRetry, "ApiKeys retries one transient certified read and publishes only its retry")
        expect(readDurability.persistentFailureClosed, "ApiKeys exposes no value after two uncertified runtime reads")
        expect(readDurability.runtimePreserved, "ApiKeys preserves the prior published value after read failure")

        let writeDurability = failedWriteRetriesAndPreservesPrior()
        expect(writeDurability.transientRetry, "ApiKeys retries one transient write and syncs after confirmation")
        expect(writeDurability.persistentFailureClosed, "ApiKeys restores the prior value after two failed writes")
        expect(writeDurability.syncOnlyAfterConfirmation, "ApiKeys does not schedule sync for an unconfirmed write")

        let c = contracts()
        let apiKeysHasScope = c.apiKeys.contains("enum ApiKeySlots")
            && c.apiKeys.contains("CredentialScope")
            && c.apiKeys.contains("migrateLegacyIfEligible")
            && c.apiKeys.contains("func bind(owner")
            && c.apiKeys.contains("Keychain.confirmedString")
            && c.apiKeys.contains("Keychain.durableString")
            && c.apiKeys.contains("claimGlobalSlot(")
            && c.apiKeys.contains("CredentialMutationResult.success")
        expect(apiKeysHasScope, "ApiKeys production code owns typed scoped slots and authenticated migration")
        let managerBindsApiKeys = c.syncManager.contains("ApiKeys.shared.bind(owner: scope)")
            && c.syncManager.contains("ApiKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)")
        expect(managerBindsApiKeys, "VortXSyncManager binds and migrates ApiKeys at account transitions")

        expect(runtimeRestoreEvents(read: .failure, persistedValueIsValid: false).isEmpty,
               "runtime restore does not delete, bind, or migrate after a certified read failure")
        expect(runtimeRestoreEvents(read: .missing, persistedValueIsValid: false).isEmpty,
               "runtime restore declines a certified missing session without mutation")
        expect(runtimeRestoreEvents(read: .value("malformed"), persistedValueIsValid: false) == [.deleteMalformedValue],
               "runtime restore deletes only a definitely present malformed persisted value")
        expect(runtimeRestoreEvents(read: .value("valid"), persistedValueIsValid: true)
                   == [.bindOwner, .authenticateOwner, .migrateCredentials],
               "runtime restore binds, authenticates, then migrates a valid certified value")
        expect(runtimeRestoreSourceContract(c.syncManager),
               "VortXSyncManager restore implements the certified failure/missing/value decision boundary")

        expect(ownerCompositionEvents(
            ownerAcquired: false,
            ownerEstablished: false,
            traktRawClaimSucceeded: false,
            simklRawClaimSucceeded: false
        ).isEmpty,
        "a failed owner acquisition leaves ApiKeys, Debrid, source-index, and session state untouched")
        expect(ownerCompositionEvents(
            ownerAcquired: true,
            ownerEstablished: false,
            traktRawClaimSucceeded: true,
            simklRawClaimSucceeded: true
        ) == [.acquireOwner, .bindCredentialStores, .sourceIndexWillMutate, .publishSession],
        "unproven ownership cannot claim or finalize provider credentials")
        expect(ownerCompositionEvents(
            ownerAcquired: true,
            ownerEstablished: true,
            traktRawClaimSucceeded: false,
            simklRawClaimSucceeded: false
        ) == [.acquireOwner, .bindCredentialStores, .sourceIndexWillMutate, .publishSession,
              .establishAuthenticatedOwner],
        "a failed provider raw claim cannot finalize a provider session")
        expect(ownerCompositionEvents(
            ownerAcquired: true,
            ownerEstablished: true,
            traktRawClaimSucceeded: true,
            simklRawClaimSucceeded: false
        ) == [.acquireOwner, .bindCredentialStores, .sourceIndexWillMutate, .publishSession,
              .establishAuthenticatedOwner, .claimTraktLegacySlots, .finalizeTraktLegacySlots],
        "a failed SIMKL raw claim cannot starve successful Trakt finalization")
        expect(ownerCompositionEvents(
            ownerAcquired: true,
            ownerEstablished: true,
            traktRawClaimSucceeded: false,
            simklRawClaimSucceeded: true
        ) == [.acquireOwner, .bindCredentialStores, .sourceIndexWillMutate, .publishSession,
              .establishAuthenticatedOwner, .claimSIMKLLegacySlots, .finalizeSIMKLLegacySlots],
        "a failed Trakt raw claim cannot starve successful SIMKL finalization")
        expect(ownerCompositionEvents(
            ownerAcquired: true,
            ownerEstablished: true,
            traktRawClaimSucceeded: true,
            simklRawClaimSucceeded: true
        ) == [.acquireOwner, .bindCredentialStores, .sourceIndexWillMutate, .publishSession,
              .establishAuthenticatedOwner,
              .claimTraktLegacySlots, .finalizeTraktLegacySlots,
              .claimSIMKLLegacySlots, .finalizeSIMKLLegacySlots],
        "each provider finalization follows its own successful authenticated raw claim")
        expect(credentialCompositionSourceContract(c.syncManager),
               "VortXSyncManager acquires optional ownership before mutation and boundedly finalizes provider migration")
        expect(ownerAcquisitionTrace(denialsBeforeSuccess: 2)
               == OwnerAcquisitionTrace(
                deniedAttemptLogs: [1, 2], exhaustedLogs: 0, successfulApplications: 1),
               "two denied owner attempts are logged before one successful protected transition")
        expect(ownerAcquisitionTrace(denialsBeforeSuccess: 3)
               == OwnerAcquisitionTrace(
                deniedAttemptLogs: [1, 2, 3], exhaustedLogs: 1, successfulApplications: 0),
               "three denied owner attempts log every denial and one bounded exhaustion without mutation")
        expect(ownerAcquisitionTrace(denialsBeforeSuccess: 2, supersededAfterAttempt: 1)
               == OwnerAcquisitionTrace(
                deniedAttemptLogs: [1], exhaustedLogs: 0, successfulApplications: 0),
               "a newer auth generation drops a stale owner retry without applying its captured intent")
        expect(credentialOwnerRetrySourceContract(c.syncManager),
               "restore, sign-out, and adopt production paths retry denied owner acquisition with logging and generation fences")
        expect(signOutDurabilitySourceContract(c.syncManager),
               "sign-out certifies durable session deletion before live publication and retries a failed deletion")
        let signOutExecution = executableSignOutDurabilityScenarios()
        expect(signOutExecution.failedDeletePreservesOwners,
               "failed durable deletion leaves registry, ApiKeys, Debrid, and live session owners unchanged")
        expect(signOutExecution.staleAfterDeletePreservesOwners,
               "a superseding owner after deletion blocks stale bind and publication")
        expect(signOutExecution.busyBindPreservesAndRetries,
               "a busy post-delete owner bind retains live projection and retries idempotent delete then bind")
        let adoptDurability = executableAdoptDurabilityScenarios()
        expect(adoptDurability.failurePreservesProjection,
               "a failed certified adopt write cannot flip owners or publish a signed-in projection")
        expect(adoptDurability.repairThenPublishesOnce,
               "a later certified adopt write flips owners and publishes exactly once")
        let unsafeSignOutOrdering = c.syncManager.replacingOccurrences(
            of: "        guard deletePersistedSession() == .success else { return false }\n"
                + "        guard isPreSignOutCurrent() else { return false }",
            with: "        guard isPreSignOutCurrent() else { return false }\n"
                + "        publishSignedOutState()\n"
                + "        guard deletePersistedSession() == .success else { return false }")
        expect(unsafeSignOutOrdering != c.syncManager
               && !signOutDurabilitySourceContract(unsafeSignOutOrdering),
               "the sign-out gate rejects live publication moved before durable deletion")
        let prematureSignOutBind = c.syncManager.replacingOccurrences(
            of: "        guard deletePersistedSession() == .success else { return false }\n"
                + "        guard isPreSignOutCurrent() else { return false }\n"
                + "        guard bindSignedOutOwner() else { return false }",
            with: "        guard bindSignedOutOwner() else { return false }\n"
                + "        guard deletePersistedSession() == .success else { return false }\n"
                + "        guard isPreSignOutCurrent() else { return false }")
        expect(prematureSignOutBind != c.syncManager
               && !signOutDurabilitySourceContract(prematureSignOutBind),
               "the sign-out gate rejects owner rebinding before durable deletion")
        let ignoredSignOutDelete = c.syncManager.replacingOccurrences(
            of: "guard deletePersistedSession() == .success else { return false }",
            with: "_ = deletePersistedSession()")
        expect(ignoredSignOutDelete != c.syncManager
               && !signOutDurabilitySourceContract(ignoredSignOutDelete),
               "the sign-out gate rejects an ignored durable deletion result")

        expect(authenticatedVortXRequestSourceContract(c.syncManager),
               "VortX manager routes every auth, bearer, QR, and backup request through the bounded shared transport")
        let broadBackupCap = c.syncManager.replacingOccurrences(
            of: "path == \"/v1/backup\"",
            with: "path.hasPrefix(\"/v1/backup\")")
        expect(broadBackupCap != c.syncManager
               && !authenticatedVortXRequestSourceContract(broadBackupCap),
               "the VortX request cap gate allows the snapshot limit only for the exact backup path")
        let controlInheritsSnapshotCap = c.syncManager.replacingOccurrences(
            of: ": AuthenticatedHTTPTransport.controlResponseLimit",
            with: ": AuthenticatedHTTPTransport.snapshotResponseLimit")
        expect(controlInheritsSnapshotCap != c.syncManager
               && !authenticatedVortXRequestSourceContract(controlInheritsSnapshotCap),
               "the VortX request cap gate prevents control, auth, recovery, QR, and me paths from inheriting the backup allowance")
        expect(adoptDurabilitySourceContract(c.syncManager, credentialScope: c.credentialScope),
               "VortX adopt certifies persistence inside owner acquisition before any owner or live session publication")
        expect(providerAdoptionSettlementSourceContract(c.syncManager),
               "VortX settles remote Trakt and SIMKL adoption before acknowledging an account document version")
        let providerStampBeforeAwait = c.syncManager.replacingOccurrences(
            of: "        let providerSettlement: CredentialProviderRetryOutcome\n        if let pending = providerPlan {",
            with: "        lastSyncedVersion = max(lastSyncedVersion, pulled.version)\n"
                + "        let providerSettlement: CredentialProviderRetryOutcome\n        if let pending = providerPlan {")
        expect(providerStampBeforeAwait != c.syncManager
               && !providerAdoptionSettlementSourceContract(providerStampBeforeAwait),
               "the provider settlement gate rejects an acknowledgement stamped before provider adoption settles")
        let discardedProviderTask = c.syncManager.replacingOccurrences(
            of: "return await TraktAuth.shared.adoptTokens(",
            with: "Task { _ = await TraktAuth.shared.adoptTokens(")
        expect(discardedProviderTask != c.syncManager
               && !providerAdoptionSettlementSourceContract(discardedProviderTask),
               "the provider settlement gate rejects a discarded unstructured Trakt adoption task")

        let productionBodyProof = productionCredentialBodyGateProof(c.syncManager)
        expect(productionBodyProof.productionAccepted,
               "the compiler-derived statement gate accepts the exact production manager bodies")
        expect(productionBodyProof.bindMutationRejected,
               "the compiler-derived gate rejects a dependent mutation inserted before tryBind")
        expect(productionBodyProof.bindFailureMutationRejected,
               "the compiler-derived gate rejects a dependent mutation in tryBind's failure branch")
        expect(productionBodyProof.restoreMutationRejected,
               "the compiler-derived gate rejects a restore mutation inserted before owner acquisition")
        expect(productionBodyProof.restoreDenialMutationRejected,
               "the compiler-derived gate rejects a restore mutation on the denied-acquisition continuation")
        expect(productionBodyProof.restoreElseMutationRejected,
               "the compiler-derived gate rejects a restore mutation hidden in an acquisition-failure else")
        expect(productionBodyProof.signOutMutationRejected,
               "the compiler-derived gate rejects a sign-out mutation inserted before owner acquisition")
        expect(productionBodyProof.signOutDenialMutationRejected,
               "the compiler-derived gate rejects a sign-out mutation on the denied-acquisition continuation")
        expect(productionBodyProof.signOutElseMutationRejected,
               "the compiler-derived gate rejects a sign-out mutation hidden in an acquisition-failure else")
        expect(productionBodyProof.adoptMutationRejected,
               "the compiler-derived gate rejects an adopt mutation inserted before owner acquisition")
        expect(productionBodyProof.adoptFailureMutationRejected,
               "the compiler-derived gate rejects a dependent mutation in adopt's acquisition failure branch")
        expect(productionBodyProof.malformedCleanupMutationRejected,
               "the compiler-derived gate rejects an extra dependent mutation hidden in malformed cleanup")
        expect(productionBodyProof.malformedCleanupSessionMutationRejected,
               "the compiler-derived gate rejects a session mutation nested in the certified Keychain expression")
        expect(productionBodyProof.harmlessPreludeAccepted,
               "the compiler-derived gate permits decode and validation work before owner acquisition")

        let ownerRetryExecution = await executableOwnerRetryScenarios()
        expect(ownerRetryExecution.denialThenSuccess,
               "the production owner-retry helper acquires once after two logged denials")
        expect(ownerRetryExecution.exhaustionLogged,
               "the production owner-retry helper logs every denial and one bounded exhaustion")
        expect(ownerRetryExecution.supersessionDrops,
               "the production owner-retry helper drops a retry superseded during suspension")
        expect(ownerRetryExecution.retainedTaskCompletes,
               "the production task launcher retains a retry through its successful terminal result")

        let providerSettlement = await executableProviderAdoptionSettlementScenarios()
        expect(providerSettlement.traktFailureRemainsPending,
               "a failed remote Trakt adoption leaves only Trakt pending and leaves the document unacknowledged")
        expect(providerSettlement.simklFailureRemainsPending,
               "a failed remote SIMKL adoption leaves only SIMKL pending and leaves the document unacknowledged")
        expect(providerSettlement.asymmetricRetryAvoidsDuplicate,
               "a successful provider is not re-adopted while its failed sibling retries")
        expect(providerSettlement.accountSwitchCannotAcknowledgeOrWrite,
               "a switched credential capture cannot write a provider or acknowledge the old account document")

        let simklRecovery = await executableProviderRetry(firstClaimDenials: 0, secondClaimDenials: 2)
        expect(simklRecovery.completed
               && simklRecovery.probe.firstClaims == 1
               && simklRecovery.probe.firstFinalizations == 1
               && simklRecovery.probe.secondClaims == 3
               && simklRecovery.probe.secondFinalizations == 1,
               "SIMKL claim recovery cannot repeat or starve a completed Trakt finalization")
        let traktRecovery = await executableProviderRetry(firstClaimDenials: 2, secondClaimDenials: 0)
        expect(traktRecovery.completed
               && traktRecovery.probe.firstClaims == 3
               && traktRecovery.probe.firstFinalizations == 1
               && traktRecovery.probe.secondClaims == 1
               && traktRecovery.probe.secondFinalizations == 1,
               "Trakt claim recovery cannot repeat or starve a completed SIMKL finalization")
        expect(await executableProviderSupersession(),
               "provider finalization drops the exact owner capture after supersession during suspension")

        let syncDown = c.syncManager.range(of: "if let keys = doc[\"apiKeys\"]")
            .map { String(c.syncManager[$0.lowerBound...]) } ?? ""
        let firstTMDBApply = syncDown.range(of: "ApiKeys.shared.tmdb")?.lowerBound
        let firstGuard = syncDown.range(of: "guard isCurrent(capture)")?.lowerBound
        expect(firstTMDBApply != nil && firstGuard != nil && firstGuard! < firstTMDBApply!,
               "syncDown authority-checks before any ApiKeys remote application")

        let merge = c.syncManager.range(of: "private func mergeLocalIntoDoc")
            .map { String(c.syncManager[$0.lowerBound...]) } ?? ""
        let pushFenceBeforeRead = merge.contains(
            "guard isCurrent(capture) else { return nil }\n        var keys = (doc[\"apiKeys\"]")
        expect(pushFenceBeforeRead,
               "push authority-checks before reading any ApiKeys credential")

        if failures.isEmpty {
            print("PASS: \(checks) ApiKeys credential security checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
