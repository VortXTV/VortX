package com.vortx.android.engine

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProfileTokenAuthenticationTest {
    @Test fun `delayed verified preview survives only its own principal bind`() {
        val original = HomeProfileIdentity("viewer", true, "slot", null)
        val fence = HomePrivacyFence(initialProfile = original)
        val attempt = fence.beginSignIn("token-request")
        val delayed = fence.previewTicket(1)
        val proof = fence.capturePrincipalBinding(attempt, "verified-uid")
        val bound = original.copy(expectedPrincipal = "viewer@example.com")
        fence.switchProfile(bound, 2)
        assertTrue(fence.completeSignIn(fence.resumeAfterPrincipalBinding(proof, 2), "verified-uid"))
        assertTrue(fence.isRaised)
        assertFalse(fence.noteContinueWatchingRefresh(delayed, "other-uid"))
        assertTrue(fence.noteContinueWatchingRefresh(delayed, "verified-uid"))
        assertFalse(fence.isRaised)
        fence.switchProfile(original.copy(profileId = "other"), 3)
        fence.switchProfile(bound, 4)
        assertFalse(fence.noteContinueWatchingRefresh(delayed, "verified-uid"))
    }

    @Test fun `first verified principal binding retains witnessed preview for the same profile and slot`() {
        val original = HomeProfileIdentity("viewer", true, "slot", null)
        val fence = HomePrivacyFence(initialProfile = original)
        val attempt = fence.beginSignIn("token-request")
        fence.noteContinueWatchingRefresh(fence.previewTicket(1), "verified-uid")
        val proof = fence.capturePrincipalBinding(attempt, "verified-uid")
        fence.switchProfile(original.copy(expectedPrincipal = "viewer@example.com"), 2)
        val rebound = fence.resumeAfterPrincipalBinding(proof, 2)
        assertTrue(fence.completeSignIn(rebound, "verified-uid"))
        assertFalse(fence.isRaised)
    }

    @Test fun `principal binding cannot manufacture a missing preview or transfer it to another profile`() {
        val original = HomeProfileIdentity("viewer", true, "slot", null)
        val fence = HomePrivacyFence(initialProfile = original)
        val attempt = fence.beginSignIn("token-request")
        val proof = fence.capturePrincipalBinding(attempt, "verified-uid")
        fence.switchProfile(original.copy(expectedPrincipal = "viewer@example.com"), 2)
        assertTrue(fence.completeSignIn(fence.resumeAfterPrincipalBinding(proof, 2), "verified-uid"))
        assertTrue(fence.isRaised)
        fence.switchProfile(original.copy(profileId = "another-profile"), 3)
        try { fence.resumeAfterPrincipalBinding(proof, 3); fail("Another profile borrowed preview proof") }
        catch (_: IllegalStateException) { }
    }

    @Test fun `token action is the supported core auth request`() {
        val encoded = JSONObject(EngineActions.authenticateToken("synthetic-token"))
        assertTrue(encoded.isNull("field"))
        val contextAction = encoded.getJSONObject("action")
        assertEquals("Ctx", contextAction.getString("action"))
        val auth = contextAction.getJSONObject("args")
        assertEquals("Authenticate", auth.getString("action"))
        val request = auth.getJSONObject("args")
        assertEquals("LoginWithToken", request.getString("type"))
        assertEquals("synthetic-token", request.getString("token"))
    }

    @Test fun `token completion and failure match exact request fingerprint`() {
        val fingerprint = EngineState.tokenAuthRequestId("synthetic-token")
        assertNotEquals(fingerprint, EngineState.tokenAuthRequestId("replacement-token"))
        assertNotEquals(fingerprint, EngineState.authRequestId("synthetic-token", ""))
        assertEquals(AuthAttemptOutcome.Succeeded(fingerprint), EngineState.parseAuthAttemptOutcome(
            """{"name":"CoreEvent","args":{"event":"UserAuthenticated","args":{"auth_request":{"type":"LoginWithToken","token":"synthetic-token"}}}}"""))
        assertEquals(AuthAttemptOutcome.Failed(fingerprint, "Expired"), EngineState.parseAuthAttemptOutcome(
            """{"name":"CoreEvent","args":{"event":"Error","args":{"error":{"message":"Expired"},"source":{"event":"UserAuthenticated","args":{"auth_request":{"type":"LoginWithToken","token":"synthetic-token"}}}}}}"""))
        assertNull(EngineState.parseAuthAttemptOutcome(
            """{"name":"CoreEvent","args":{"event":"UserAuthenticated","args":{"auth_request":{"type":"LoginWithToken"}}}}"""))
    }

    @Test fun `abandoned token ACK cannot complete identical replacement lease`() = runBlocking {
        val coordinator = AuthAttemptCoordinator()
        val fingerprint = EngineState.tokenAuthRequestId("synthetic-token")
        val first = checkNotNull(coordinator.begin(fingerprint))
        assertTrue(coordinator.abandon(first))
        assertNull(coordinator.begin(fingerprint))
        assertFalse(coordinator.complete(AuthAttemptOutcome.Succeeded(fingerprint)))
        val replacement = checkNotNull(coordinator.begin(fingerprint))
        assertFalse(replacement.outcome.isCompleted)
        assertTrue(coordinator.complete(AuthAttemptOutcome.Succeeded(fingerprint)))
        assertEquals(AuthAttemptOutcome.Succeeded(fingerprint), replacement.outcome.await())
    }
}
