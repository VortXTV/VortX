import Foundation

@main
struct VortxNativeOAuthIntentTests {
    static func check(_ value: Bool) { precondition(value) }
    @MainActor static func main() async throws {
        let scope = CredentialScope(canonicalRemoteAccountID: "00000000-0000-0000-0000-000000000123")!
        let capture = CredentialScopeRegistry.shared.bind(scope)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        let auth = SIMKLAuth(credentials: MemorySIMKLCredentials().store)
        let manager = VortXSyncManager.shared
        let live: [String: VortxJSON] = ["simklAccess": .string("fixture-initial"), "simklExpiry": .string("0")]
        let cleared: [String: VortxJSON] = ["simklAccess": .null, "simklExpiry": .null]
        let initial = manager.prepareNativeProviderMutation(live, capture: capture)!
        check(await auth.adoptTokens(access: "fixture-initial", expiryUnix: 0, ownerCapture: capture) == .success)
        precondition(manager.finishNativeProviderMutation(initial, capture: capture))
        let firstSession = await auth.sessionID

        // Failed preflight never touches the real OAuth tuple.
        Keychain.ignoreNextWrite()
        let preflightRejected = await auth.signOut()
        precondition(!preflightRejected)
        check(await auth.sessionID == firstSession)

        // Fail only the post-clear journal finalization. The already-certified prepared tombstone
        // survives, blocks stale remote application, and an explicit retry durably completes it.
        SIMKLAuthBoundary.observe(key: "native-intent-finalize-failure") { session in
            if session == nil { Keychain.ignoreNextWrite() }
        }
        let finishRejected = await auth.signOut()
        SIMKLAuthBoundary.removeObserver(key: "native-intent-finalize-failure")
        precondition(!finishRejected)
        check(await auth.sessionID == nil)
        let journal = try manager.testProviderState(capture: capture)
        precondition(journal.hasPreparedMutation)
        var blocked = journal
        do { try blocked.merge(nil); preconditionFailure("unsettled OAuth mutation admitted remote sync") } catch {}
        precondition(!VortXSyncManager.withNativeProviderEvents(initial, capture: capture, mutation: { preconditionFailure("old event authorized") }))
        let retainedClear = journal.local.prepared!
        check(await auth.certifiesNativePrepared(retainedClear, capture: capture))
        check(manager.finishNativeProviderMutation(retainedClear, capture: capture))
        check(try !manager.testProviderState(capture: capture).hasPreparedMutation)

        // A delayed pulled tombstone must not erase a newer same-account reconnect. This calls
        // the real actor boundary with an old event after a real secure tuple replacement.
        let oldClear = try manager.testProviderState(capture: capture).local.document.fields
        let oldSnapshot = try manager.testProviderState(capture: capture).local.document
        let reconnected: [String: VortxJSON] = ["simklAccess": .string("fixture-reconnected"), "simklExpiry": .string("0")]
        let reconnect = manager.prepareNativeProviderMutation(reconnected, capture: capture)!
        check(await auth.adoptTokens(access: "fixture-reconnected", expiryUnix: 0, ownerCapture: capture) == .success)
        precondition(manager.finishNativeProviderMutation(reconnect, capture: capture))
        let newSession = await auth.sessionID
        check(!(await auth.applyNativeCredentialClear(capture: capture, events: oldClear)))
        check(await auth.sessionID == newSession)
        check(await auth.adoptTokens(access: "fixture-stale-remote", expiryUnix: 0, ownerCapture: capture,
            mutationGuard: { mutate in VortXSyncManager.withNativeProviderSnapshot(oldSnapshot, capture: capture, mutation: mutate) }) == .failure)
        check(await auth.sessionID == newSession)

        // Race at the actual clear linearization point: hold the shared credential publication
        // gate while a newer prepared intent arrives, then release the delayed clear.
        let clearIntent = manager.prepareNativeProviderMutation(cleared, capture: capture)!
        precondition(manager.finishNativeProviderMutation(clearIntent, capture: capture))
        let lease = CredentialPublicationOutbox.beginMutation()!
        let delayed = Task { await auth.applyNativeCredentialClear(capture: capture, events: clearIntent) }
        for _ in 0..<1000 {
            if await auth.isCredentialBoundaryPending { break }
            await Task.yield()
        }
        let newerPrepared = manager.prepareNativeProviderMutation(reconnected, capture: capture)!
        CredentialPublicationOutbox.endMutation(lease)
        check(!(await delayed.value))
        check(await auth.sessionID == newSession)
        precondition(manager.finishNativeProviderMutation(newerPrepared, capture: capture))
        print("Native OAuth production integration: failed prepare leaves tuple, failed finalize retains durable clear, retry settles, stale/newly-prepared same-account clear races rejected")
    }
}
