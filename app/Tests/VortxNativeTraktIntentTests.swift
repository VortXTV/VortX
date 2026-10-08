import Foundation

@main
struct VortxNativeTraktIntentTests {
    static func check(_ value: Bool) { precondition(value) }
    @MainActor static func main() async throws {
        let scope = CredentialScope(canonicalRemoteAccountID: "00000000-0000-0000-0000-000000000123")!
        let capture = CredentialScopeRegistry.shared.bind(scope)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let auth = TraktAuth(sessionConfiguration: configuration, credentials: MemoryCredentials().store,
            configuration: TraktAuthConfiguration(clientID: "fixture", apiBase: "https://fixture.invalid", brokerBase: "https://fixture.invalid"),
            oauthRequestSigner: { request, _ in request })
        let manager = VortXSyncManager.shared
        let live: [String: VortxJSON] = ["traktAccess": .string("fixture-initial"), "traktRefresh": .string("fixture-refresh"), "traktExpiry": .string("0")]
        let initial = manager.prepareNativeProviderMutation(live, capture: capture)!
        check(await auth.adoptTokens(access: "fixture-initial", refresh: "fixture-refresh", expiryUnix: 0, ownerCapture: capture) == .success)
        check(manager.finishNativeProviderMutation(initial, capture: capture))
        let firstSession = await auth.sessionID
        Keychain.ignoreNextWrite()
        check(!(await auth.revokeAndSignOut()))
        check(await auth.sessionID == firstSession)

        TraktAuthBoundary.observe(key: "native-intent-finalize-failure") { session in
            if session == nil { Keychain.ignoreNextWrite() }
        }
        check(!(await auth.revokeAndSignOut()))
        TraktAuthBoundary.removeObserver(key: "native-intent-finalize-failure")
        check(await auth.sessionID == nil)
        let retained = try manager.testProviderState(capture: capture).local.prepared!
        check(await auth.certifiesNativePrepared(retained, capture: capture))
        check(manager.finishNativeProviderMutation(retained, capture: capture))
        let oldSnapshot = try manager.testProviderState(capture: capture).local.document
        let newer = manager.prepareNativeProviderMutation(live, capture: capture)!
        check(await auth.adoptTokens(access: "fixture-initial", refresh: "fixture-refresh", expiryUnix: 0, ownerCapture: capture) == .success)
        check(manager.finishNativeProviderMutation(newer, capture: capture))
        let currentSession = await auth.sessionID
        check(!(await auth.applyNativeCredentialClear(capture: capture, events: oldSnapshot.fields)))
        check(await auth.adoptTokens(access: "fixture-stale", refresh: "fixture-stale-refresh", expiryUnix: 0, ownerCapture: capture,
            mutationGuard: { mutate in VortXSyncManager.withNativeProviderSnapshot(oldSnapshot, capture: capture, mutation: mutate) }) == .failure)
        check(await auth.sessionID == currentSession)
        print("Native Trakt production integration: prepare failure preserves tuple, failed clear finalization retains intent, certified recovery and stale clear/adoption fences pass")
    }
}
