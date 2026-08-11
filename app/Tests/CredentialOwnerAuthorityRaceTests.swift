// Standalone adversarial tests for the shared Apple credential authority primitives.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/credential-owner-authority-race \
//     app/SourcesShared/CredentialScope.swift \
//     app/Tests/CredentialOwnerAuthorityRaceTests.swift && /tmp/credential-owner-authority-race

import Foundation

private final class MemorySlots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writes: [(value: String?, key: String)] = []
    private var ignoredWrites = Set<String>()
    private var ignoredDeletes = Set<String>()

    func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func write(_ value: String?, _ key: String) -> CredentialMutationResult {
        lock.lock()
        writes.append((value, key))
        if value != nil, ignoredWrites.remove(key) != nil {
            lock.unlock()
            return .failure
        }
        if value == nil, ignoredDeletes.remove(key) != nil {
            lock.unlock()
            return .failure
        }
        values[key] = value
        lock.unlock()
        return .success
    }

    func durableRead(_ key: String) -> CredentialDurableReadResult {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return .missing }
        return .value(value)
    }

    func ignoreNextWrite(to key: String) {
        lock.lock()
        ignoredWrites.insert(key)
        lock.unlock()
    }

    func ignoreNextDelete(of key: String) {
        lock.lock()
        ignoredDeletes.insert(key)
        lock.unlock()
    }

    func wroteValue(to key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writes.contains { $0.key == key && $0.value != nil }
    }

    func deleted(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writes.contains { $0.key == key && $0.value == nil }
    }

    func valueWriteIndex(_ key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return writes.firstIndex { $0.key == key && $0.value != nil }
    }

    func deleteWriteIndex(_ key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return writes.firstIndex { $0.key == key && $0.value == nil }
    }
}

@MainActor
private func runTests() async {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    let canonical = "01234567-89ab-cdef-0123-456789abcdef"
    let owner = CredentialScope(canonicalRemoteAccountID: canonical)
    expect(owner == .account(UUID(uuidString: canonical)!), "lowercase UUID should be an account owner")
    expect(CredentialScope(canonicalRemoteAccountID: canonical.uppercased()) == nil,
           "uppercase UUID must not alias the lowercase owner")
    expect(CredentialScope(canonicalRemoteAccountID: "acct_1") == nil,
           "non-UUID account identifiers must fail closed")

    let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
    let signedOutCapture = authority.capture()
    expect(!authority.isMigrationEligible(signedOutCapture),
           "signed-out device must not be eligible to consume global credentials")
    expect(authority.establishAuthenticatedOwner(signedOutCapture) == nil,
           "signed-out state cannot establish migration authority")
    let unprovenA = authority.bind(owner!)
    expect(!authority.isMigrationEligible(unprovenA),
           "a merely bound first account must not be eligible to consume global credentials")
    let provenA = authority.establishAuthenticatedOwner(unprovenA)
    expect(provenA != nil, "an explicitly established authenticated account becomes eligible")
    expect(authority.isMigrationEligible(provenA!), "the established account proof must remain current")
    let captureB = authority.bind(.account(UUID(uuidString: "fedcba98-7654-3210-fedc-ba9876543210")!))
    expect(!authority.isMigrationEligible(captureB),
           "a switched account must not inherit the prior account's migration proof")
    expect(authority.establishAuthenticatedOwner(provenA!) == nil,
           "a stale account capture cannot regain migration authority")
    expect(!authority.isCurrent(provenA!), "an account switch must invalidate the old capture")
    expect(authority.isCurrent(captureB), "the newest account capture must remain current")

    let slots = MemorySlots()
    slots.write("legacy-token", "legacy")
    let migrated = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy",
        destinationAccount: "account.A",
        claimMarkerAccount: "legacy.claim",
        ownerNamespace: "account.A",
        write: slots.write,
        durableRead: slots.durableRead
    )
    expect(migrated == .migrated, "legacy migration should claim and move the token")
    expect(slots.read("legacy") == nil, "legacy source is removed only after the destination is verified")
    expect(slots.read("account.A") == "legacy-token", "claimed token must land in owner A")
    let secondOwner = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy",
        destinationAccount: "account.B",
        claimMarkerAccount: "legacy.claim",
        ownerNamespace: "account.B",
        write: slots.write,
        durableRead: slots.durableRead
    )
    expect(secondOwner == .claimedByOtherOwner, "a second owner must not reclaim the legacy source")
    expect(slots.read("account.B") == nil, "a rejected claimant must not receive the token")

    let eligibilitySlots = MemorySlots()
    eligibilitySlots.write("unclaimed", "legacy-eligible")
    let claimOnlyIfEligible: (CredentialScopeRegistry, CredentialScopeRegistry.Capture, String) -> CredentialLegacyClaim.Result = { registry, capture, destination in
        guard registry.isMigrationEligible(capture) else { return .noSource }
        return CredentialLegacyClaim.claimGlobalSlot(
            sourceAccount: "legacy-eligible",
            destinationAccount: destination,
            claimMarkerAccount: "legacy-eligible.claim",
            ownerNamespace: capture.namespace,
            write: eligibilitySlots.write,
            durableRead: eligibilitySlots.durableRead)
    }
    expect(claimOnlyIfEligible(authority, signedOutCapture, "account.signed-out") == .noSource,
           "signed-out migration attempt must leave the global source untouched")
    expect(eligibilitySlots.read("legacy-eligible") == "unclaimed",
           "signed-out migration denial must not consume the source")
    let unprovenAuthority = CredentialScopeRegistry(initialScope: .signedOutDevice)
    let unprovenCapture = await MainActor.run { unprovenAuthority.bind(owner!) }
    expect(claimOnlyIfEligible(unprovenAuthority, unprovenCapture, "account.unproven") == .noSource,
           "an unproven first account must not consume the global source")
    expect(eligibilitySlots.read("legacy-eligible") == "unclaimed",
           "an unproven account denial must leave the global source untouched")
    let eligibleCapture = await MainActor.run {
        unprovenAuthority.establishAuthenticatedOwner(unprovenCapture)!
    }
    expect(claimOnlyIfEligible(unprovenAuthority, eligibleCapture, "account.proven") == .migrated,
           "only a proven account may claim the legacy source")

    let orderSlots = MemorySlots()
    orderSlots.write("ordered-token", "legacy-order")
    let ordered = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy-order",
        destinationAccount: "account.order",
        claimMarkerAccount: "legacy-order.claim",
        ownerNamespace: "account.order",
        write: orderSlots.write,
        durableRead: orderSlots.durableRead)
    expect(ordered == .migrated, "destination-first migration should succeed")
    expect(orderSlots.wroteValue(to: "account.order"), "migration must write the destination")
    expect(orderSlots.deleted("legacy-order"), "migration must delete the source after destination verification")
    expect((orderSlots.valueWriteIndex("account.order") ?? .max) < (orderSlots.deleteWriteIndex("legacy-order") ?? .min),
           "destination write must precede source deletion")

    let destinationFailure = MemorySlots()
    destinationFailure.write("retry-token", "legacy-destination-failure")
    destinationFailure.ignoreNextWrite(to: "account.destination-failure")
    let failedDestination = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy-destination-failure",
        destinationAccount: "account.destination-failure",
        claimMarkerAccount: "legacy-destination-failure.claim",
        ownerNamespace: "account.destination-failure",
        write: destinationFailure.write,
        durableRead: destinationFailure.durableRead)
    expect(failedDestination == .targetReadbackMismatch,
           "a destination readback failure must fail closed")
    expect(destinationFailure.read("legacy-destination-failure") == "retry-token",
           "a failed destination write must leave the source available for retry")
    let retriedDestination = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy-destination-failure",
        destinationAccount: "account.destination-failure",
        claimMarkerAccount: "legacy-destination-failure.claim",
        ownerNamespace: "account.destination-failure",
        write: destinationFailure.write,
        durableRead: destinationFailure.durableRead)
    expect(retriedDestination == .migrated && destinationFailure.read("legacy-destination-failure") == nil,
           "a destination failure must be retry-safe")

    let sourceFailure = MemorySlots()
    sourceFailure.write("delete-retry-token", "legacy-source-failure")
    sourceFailure.ignoreNextDelete(of: "legacy-source-failure")
    let failedSource = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy-source-failure",
        destinationAccount: "account.source-failure",
        claimMarkerAccount: "legacy-source-failure.claim",
        ownerNamespace: "account.source-failure",
        write: sourceFailure.write,
        durableRead: sourceFailure.durableRead)
    expect(failedSource == .sourceDeleteFailed,
           "a source deletion failure must be reported after destination verification")
    expect(sourceFailure.read("account.source-failure") == "delete-retry-token",
           "a source deletion failure must retain the verified destination")
    let retriedSource = CredentialLegacyClaim.claimGlobalSlot(
        sourceAccount: "legacy-source-failure",
        destinationAccount: "account.source-failure",
        claimMarkerAccount: "legacy-source-failure.claim",
        ownerNamespace: "account.source-failure",
        write: sourceFailure.write,
        durableRead: sourceFailure.durableRead)
    expect(retriedSource == .targetPresent && sourceFailure.read("legacy-source-failure") == nil,
           "a source deletion failure must be retry-safe")

    let multiWriteFailure = MemorySlots()
    multiWriteFailure.write("access-retry", "legacy.multi.access")
    multiWriteFailure.write("refresh-retry", "legacy.multi.refresh")
    multiWriteFailure.ignoreNextWrite(to: "account.multi.refresh")
    let failedMultiWrite = CredentialLegacyClaim.claimGlobalSlotSet(
        slots: [
            (source: "legacy.multi.access", destination: "account.multi.access"),
            (source: "legacy.multi.refresh", destination: "account.multi.refresh")
        ],
        claimMarkerAccount: "legacy.multi.claim",
        ownerNamespace: "account.multi",
        write: multiWriteFailure.write,
        durableRead: multiWriteFailure.durableRead)
    expect(failedMultiWrite == .targetReadbackMismatch,
           "a multi-slot destination failure must fail closed")
    expect(multiWriteFailure.read("legacy.multi.access") == "access-retry"
                && multiWriteFailure.read("legacy.multi.refresh") == "refresh-retry",
           "multi-slot destination failure must preserve every source")
    let retriedMultiWrite = CredentialLegacyClaim.claimGlobalSlotSet(
        slots: [
            (source: "legacy.multi.access", destination: "account.multi.access"),
            (source: "legacy.multi.refresh", destination: "account.multi.refresh")
        ],
        claimMarkerAccount: "legacy.multi.claim",
        ownerNamespace: "account.multi",
        write: multiWriteFailure.write,
        durableRead: multiWriteFailure.durableRead)
    expect(retriedMultiWrite == .migrated && multiWriteFailure.read("legacy.multi.access") == nil
                && multiWriteFailure.read("legacy.multi.refresh") == nil,
           "a multi-slot destination failure must be retry-safe")

    let multiDeleteFailure = MemorySlots()
    multiDeleteFailure.write("access-delete-retry", "legacy.delete.access")
    multiDeleteFailure.write("refresh-delete-retry", "legacy.delete.refresh")
    multiDeleteFailure.ignoreNextDelete(of: "legacy.delete.refresh")
    let failedMultiDelete = CredentialLegacyClaim.claimGlobalSlotSet(
        slots: [
            (source: "legacy.delete.access", destination: "account.delete.access"),
            (source: "legacy.delete.refresh", destination: "account.delete.refresh")
        ],
        claimMarkerAccount: "legacy.delete.claim",
        ownerNamespace: "account.delete",
        write: multiDeleteFailure.write,
        durableRead: multiDeleteFailure.durableRead)
    expect(failedMultiDelete == .sourceDeleteFailed,
           "a multi-slot source deletion failure must be reported")
    expect(multiDeleteFailure.read("account.delete.access") == "access-delete-retry"
                && multiDeleteFailure.read("account.delete.refresh") == "refresh-delete-retry",
           "multi-slot source failure must retain verified destinations")
    let retriedMultiDelete = CredentialLegacyClaim.claimGlobalSlotSet(
        slots: [
            (source: "legacy.delete.access", destination: "account.delete.access"),
            (source: "legacy.delete.refresh", destination: "account.delete.refresh")
        ],
        claimMarkerAccount: "legacy.delete.claim",
        ownerNamespace: "account.delete",
        write: multiDeleteFailure.write,
        durableRead: multiDeleteFailure.durableRead)
    expect(retriedMultiDelete == .targetPresent && multiDeleteFailure.read("legacy.delete.access") == nil
                && multiDeleteFailure.read("legacy.delete.refresh") == nil,
           "a multi-slot source failure must be retry-safe")

    let revisions = LatestCredentialReload<String>()
    _ = await revisions.submit("owner-B", revision: 2)
    _ = await revisions.submit("owner-A-stale", revision: 1)
    let current = await revisions.current()
    expect(current.revision == 2, "resolver reload revisions must be monotonic")
    expect(current.value == "owner-B", "a stale reload must not replace the newest owner")

    let resolverAuthority = CredentialScopeRegistry(initialScope: .signedOutDevice)
    let resolverA = await MainActor.run {
        let bound = resolverAuthority.bind(owner!)
        return resolverAuthority.establishAuthenticatedOwner(bound)!
    }
    let resolverReloads = LatestCredentialReload<String>()
    let delayedA = Task {
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard resolverAuthority.isMigrationEligible(resolverA) else { return }
        _ = await resolverReloads.submit("owner-A", revision: resolverA.generation)
    }
    _ = await MainActor.run {
        resolverAuthority.bind(.account(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!))
    }
    _ = await delayedA.value
    let fenced = await resolverReloads.current()
    expect(fenced.value == nil, "an old-owner warm/reload continuation must be fenced immediately")

    if failures.isEmpty {
        print("PASS credential owner authority race tests")
    } else {
        for failure in failures { print("FAIL: \(failure)") }
        exit(1)
    }
}

@main
struct CredentialOwnerAuthorityRaceTestRunner {
    @MainActor
    static func main() async {
        await runTests()
    }
}
