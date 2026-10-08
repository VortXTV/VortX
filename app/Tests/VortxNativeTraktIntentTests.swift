import Foundation

@main
struct VortxNativeTraktIntentTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "fixture assertion line \(line)") }
    @MainActor static func main() async throws {
        let scope = CredentialScope(canonicalRemoteAccountID: "00000000-0000-0000-0000-000000000123")!
        let capture = CredentialScopeRegistry.shared.bind(scope)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let auth = TraktAuth(sessionConfiguration: configuration, credentials: MemoryCredentials().store,
            configuration: TraktAuthConfiguration(clientID: "fixture", apiBase: "https://fixture.invalid", brokerBase: "https://oauth.vortx.tv"),
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
        // Cancel a real device-login attempt while its MainActor prepare is suspended. No tuple
        // mutation has happened, so only that exact prepared event must be removed.
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"session":"fixture-login","user_code":"fixture-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}"#)
        let login = try await auth.requestDeviceCode()
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"authorized","token":{"access_token":"fixture-login-access","refresh_token":"fixture-login-refresh","expires_in":3600,"token_type":"bearer","created_at":1800000000}}"#)
        manager.testActorLookupHook = {
            let completed = DispatchSemaphore(value: 0)
            Task.detached { await auth.cancelLoginAttempt(); completed.signal() }
            check(completed.wait(timeout: .now() + 5) == .success)
        }
        do { _ = try await auth.poll(session: login.session); preconditionFailure("cancelled login installed") } catch {}
        check(manager.testActorLookupHook == nil)
        check(try !manager.testProviderState(capture: capture).hasPreparedMutation)
        check(await auth.sessionID == currentSession)
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"ok","token":{"access_token":"fixture-refreshed","refresh_token":"fixture-rotated","expires_in":3600,"token_type":"bearer","created_at":1800000000}}"#)
        _ = try await auth.refresh(using: "fixture-refresh", ownerCapture: capture)
        check(try !manager.testProviderState(capture: capture).hasPreparedMutation)
        check(await auth.sessionID == currentSession)
        // Start a refresh while a real login owns the prepare/tuple/finalize boundary. The refresh
        // may complete its broker read but cannot overwrite the login's prepared event.
        let expired = manager.prepareNativeProviderMutation(live, capture: capture)!
        check(await auth.adoptTokens(access: "fixture-initial", refresh: "fixture-refresh", expiryUnix: 0, ownerCapture: capture) == .success)
        check(manager.finishNativeProviderMutation(expired, capture: capture))
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"session":"fixture-login-2","user_code":"fixture-code-2","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}"#)
        let secondLogin = try await auth.requestDeviceCode()
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"authorized","token":{"access_token":"fixture-login-winner","refresh_token":"fixture-login-winner-refresh","expires_in":3600,"token_type":"bearer","created_at":1800000000}}"#)
        var competingRefresh: Task<Bool, Never>?
        manager.testActorLookupHook = {
            let gate = HTTPRequestGate()
            FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"ok","token":{"access_token":"fixture-losing-refresh","refresh_token":"fixture-losing-refresh-token","expires_in":3600,"token_type":"bearer","created_at":1800000000}}"#, gate: gate)
            competingRefresh = Task.detached {
                do { _ = try await auth.refresh(using: "fixture-refresh", ownerCapture: capture); return false }
                catch { return true }
            }
            check(gate.waitUntilEntered()); gate.releaseResponse()
        }
        _ = try await auth.poll(session: secondLogin.session)
        check(manager.testActorLookupHook == nil)
        check(await competingRefresh!.value)
        let winner = try manager.testProviderState(capture: capture)
        check(!winner.hasPreparedMutation)
        check(winner.local.document.fields["traktAccess"]?.value == .string("fixture-login-winner"))
        // Switch accounts after the exact prepare is durably saved, before the actor can mutate.
        // Its receipt permits only local prepared cleanup in A; reopening A must not be stranded.
        let sessionBeforeSwitch = await auth.sessionID
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"session":"fixture-switch","user_code":"fixture-switch-code","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":1}"#)
        let switchingLogin = try await auth.requestDeviceCode()
        FixtureURLProtocol.fixture.set(status: 200, json: #"{"status":"authorized","token":{"access_token":"fixture-never-installed","refresh_token":"fixture-never-installed-refresh","expires_in":3600,"created_at":1800000000}}"#)
        var retiredReceipt: [String: VortxNativeProviderCredentials.Register] = [:]
        manager.testPreparedHook = {
            retiredReceipt = try! manager.testProviderState(capture: capture).local.prepared!
            _ = CredentialScopeRegistry.shared.bind(CredentialScope(canonicalRemoteAccountID: "00000000-0000-0000-0000-000000000456")!)
        }
        do { _ = try await auth.poll(session: switchingLogin.session); preconditionFailure("retired login installed") } catch {}
        check(manager.testPreparedHook == nil && !retiredReceipt.isEmpty)
        let rebound = CredentialScopeRegistry.shared.bind(scope)
        _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(rebound)
        let reopened = try manager.testProviderState(capture: rebound)
        check(!reopened.hasPreparedMutation && reopened.local.document == winner.local.document)
        check(await auth.sessionID == sessionBeforeSwitch)
        let replacementReceipt = manager.prepareNativeProviderMutation(live, capture: rebound)!
        check(!manager.abortNativeProviderMutation(retiredReceipt, capture: capture))
        check(try manager.testProviderState(capture: rebound).local.prepared == replacementReceipt)
        check(manager.abortNativeProviderMutation(replacementReceipt, capture: rebound))
        print("Native Trakt production integration: durable intent failures, exact stale apply fences, cancelled-prepare abort, and login-versus-refresh serialization passed")
    }
}
