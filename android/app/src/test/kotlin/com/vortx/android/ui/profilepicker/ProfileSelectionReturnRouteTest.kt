package com.vortx.android.ui.profilepicker

import com.vortx.android.data.AuthRepository
import com.vortx.android.model.AuthState
import com.vortx.android.profile.ProfileSelectionHandoff
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.*
import org.junit.Test

class ProfileSelectionReturnRouteTest {
    private val viewer = UserProfile(name = "Viewer", avatar = "person")
    private fun request(outcome: ProfileStore.SwitchOutcome, current: () -> Boolean = { true }) =
        ProfileSelectionRequest(viewer, outcome, null, 1L, current)

    private class Auth : AuthRepository {
        override val authState = MutableStateFlow<AuthState>(AuthState.SignedOut)
        var selection: suspend () -> Result<Boolean> = { Result.success(true) }
        var login: Result<Unit> = Result.success(Unit)
        override suspend fun completeProfileSelection(request: ProfileSelectionRequest) = selection()
        override suspend fun signInForProfileSelection(request: ProfileSelectionRequest, email: String, password: String) = login
        override suspend fun signIn(email: String, password: String): Result<Unit> = error("Unbound sign-in")
        override suspend fun signOut() = Unit
    }

    private class Host(val shellRoute: String, var profilesOpen: Boolean) {
        var pickerOpen = true
        var handoffOpen = true
        var restoredProfiles = 0
        fun finish(presentation: ProfileSelectionPresentation, handoff: ProfileSelectionHandoff) {
            // Invoke the production surface callback, including its final ownership admission.
            completeProfileSelectionPresentation(presentation, handoff,
                onComplete = { handoffOpen = false; pickerOpen = false },
                onReturnToProfiles = { profilesOpen = true; restoredProfiles++ })
        }
    }

    @Test fun `Settings same-account selection returns to its existing profile management route`() = runBlocking {
        val presentation = ProfileSelectionPresentation(request(ProfileStore.SwitchOutcome.SameAccount), ProfileSelectionOrigin.PROFILE_MANAGEMENT)
        val handoff = ProfileSelectionHandoff(Auth(), native = true)
        val host = Host("Settings", profilesOpen = true)
        handoff.select(presentation.request)
        host.finish(presentation, handoff)
        assertFalse(host.handoffOpen)
        assertFalse(host.pickerOpen)
        assertTrue(host.profilesOpen)
        assertEquals(1, host.restoredProfiles)
        assertEquals("Settings", host.shellRoute)
    }

    @Test fun `cold or current-screen picker dismissal does not open profile management or navigate the shell`() = runBlocking {
        for (underlyingRoute in listOf("Home", "Settings", "Library")) {
            val presentation = ProfileSelectionPresentation(request(ProfileStore.SwitchOutcome.SameAccount), ProfileSelectionOrigin.PICKER)
            val handoff = ProfileSelectionHandoff(Auth(), native = true)
            val host = Host(underlyingRoute, profilesOpen = false)
            handoff.select(presentation.request)
            host.finish(presentation, handoff)
            assertFalse(host.pickerOpen)
            assertFalse(host.handoffOpen)
            assertFalse(host.profilesOpen)
            assertEquals(0, host.restoredProfiles)
            assertEquals(underlyingRoute, host.shellRoute)
        }
    }

    @Test fun `Settings token handoff preserves origin and waits for actual acceptance`() = runBlocking {
        val accepted = CompletableDeferred<Result<Boolean>>()
        val auth = Auth().apply { selection = { accepted.await() } }
        val presentation = ProfileSelectionPresentation(request(ProfileStore.SwitchOutcome.SwitchAccount("synthetic-token")), ProfileSelectionOrigin.PROFILE_MANAGEMENT)
        val handoff = ProfileSelectionHandoff(auth, native = false)
        val host = Host("Settings", profilesOpen = true)
        val pending = launch { handoff.select(presentation.request) }
        yield()
        host.finish(presentation, handoff)
        assertTrue(host.handoffOpen)
        assertEquals(0, host.restoredProfiles)
        accepted.complete(Result.success(true)); pending.join()
        host.finish(presentation, handoff)
        assertFalse(host.handoffOpen)
        assertTrue(host.profilesOpen)
        assertEquals(1, host.restoredProfiles)
    }

    @Test fun `Settings sign-in stays gated on failure then returns to its origin on success`() = runBlocking {
        val auth = Auth().apply { selection = { Result.success(false) }; login = Result.failure(IllegalStateException("Synthetic rejection")) }
        val presentation = ProfileSelectionPresentation(request(ProfileStore.SwitchOutcome.NeedsSignIn), ProfileSelectionOrigin.PROFILE_MANAGEMENT)
        val handoff = ProfileSelectionHandoff(auth, native = false)
        val host = Host("Settings", profilesOpen = true)
        handoff.select(presentation.request)
        handoff.signIn(presentation.request, "viewer@example.com", "synthetic-password")
        host.finish(presentation, handoff)
        assertTrue(host.handoffOpen)
        assertEquals(0, host.restoredProfiles)
        auth.login = Result.success(Unit)
        handoff.signIn(presentation.request, "viewer@example.com", "synthetic-password")
        host.finish(presentation, handoff)
        assertFalse(host.handoffOpen)
        assertTrue(host.profilesOpen)
        assertEquals("Settings", host.shellRoute)
    }

    @Test fun `changed authority cannot restore a route from an earlier accepted selection`() = runBlocking {
        var current = true
        val presentation = ProfileSelectionPresentation(request(ProfileStore.SwitchOutcome.SameAccount) { current }, ProfileSelectionOrigin.PROFILE_MANAGEMENT)
        val handoff = ProfileSelectionHandoff(Auth(), native = true)
        val host = Host("Settings", profilesOpen = true)
        handoff.select(presentation.request)
        current = false
        host.finish(presentation, handoff)
        assertTrue(host.handoffOpen)
        assertEquals(0, host.restoredProfiles)
    }
}
