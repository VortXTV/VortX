package com.vortx.android.profile

import com.vortx.android.data.AuthRepository
import com.vortx.android.model.AuthState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class ProfileSelectionHandoffTest {
    private val profile = UserProfile(name = "Viewer", avatar = "person", usesOwnAccount = true, email = "viewer@example.com")
    private fun request(outcome: ProfileStore.SwitchOutcome, valid: () -> Boolean = { true }) =
        ProfileSelectionRequest(profile, outcome, profile.email, 1L, valid)

    @Test fun `verified first identity remains bound for a later retry`() {
        val selection = ProfileSelectionRequest(profile.copy(email = null), ProfileStore.SwitchOutcome.NeedsSignIn,
            null, 1L, { true }, bind = { true })
        assertTrue(selection.bindPrincipal(" VIEWER@example.com "))
        assertEquals("viewer@example.com", selection.expectedEmail)
    }

    @Test fun `native authority is checked again at actual picker dismissal`() = runBlocking {
        var current = true
        val coordinator = ProfileSelectionHandoff(Transport(), native = true)
        val selection = request(ProfileStore.SwitchOutcome.SameAccount) { current }
        coordinator.select(selection)
        current = false
        assertFalse(coordinator.complete(selection))
        assertEquals(ProfileSelectionHandoff.State.FAILED, coordinator.state.value)
    }

    private class Transport : AuthRepository {
        override val authState = MutableStateFlow<AuthState>(AuthState.SignedOut)
        var selected: ProfileSelectionRequest? = null
        var calls = 0
        var complete: suspend () -> Result<Boolean> = { Result.success(true) }
        var login: suspend () -> Result<Unit> = { Result.success(Unit) }
        override suspend fun completeProfileSelection(request: ProfileSelectionRequest): Result<Boolean> {
            selected = request; calls++; return complete()
        }
        override suspend fun signInForProfileSelection(request: ProfileSelectionRequest, email: String, password: String): Result<Unit> {
            assertSame(selected, request); calls++; return login()
        }
        override suspend fun signIn(email: String, password: String): Result<Unit> = error("Unbound sign-in must not run")
        override suspend fun signOut() = error("Profile selection must not revoke the outgoing token")
    }

    @Test fun `native selection dismisses without optional Stremio auth`() = runBlocking {
        val transport = Transport()
        val coordinator = ProfileSelectionHandoff(transport, native = true)
        coordinator.select(request(ProfileStore.SwitchOutcome.SameAccount))
        assertEquals(ProfileSelectionHandoff.State.COMPLETE, coordinator.state.value)
        assertEquals(0, transport.calls)
    }

    @Test fun `native selection cannot route a token through legacy auth`() = runBlocking {
        val transport = Transport()
        val coordinator = ProfileSelectionHandoff(transport, native = true)
        coordinator.select(request(ProfileStore.SwitchOutcome.SwitchAccount("synthetic-token")))
        assertEquals(ProfileSelectionHandoff.State.FAILED, coordinator.state.value)
        assertEquals(0, transport.calls)
    }

    @Test fun `same account and token results complete only after transport acceptance`() = runBlocking {
        for (outcome in listOf(ProfileStore.SwitchOutcome.SameAccount, ProfileStore.SwitchOutcome.SwitchAccount("synthetic-token"))) {
            val transport = Transport()
            val ack = CompletableDeferred<Result<Boolean>>()
            transport.complete = { ack.await() }
            val coordinator = ProfileSelectionHandoff(transport, native = false)
            val selection = request(outcome)
            val job = launch { coordinator.select(selection) }
            kotlinx.coroutines.yield()
            assertSame(selection, transport.selected)
            assertEquals(ProfileSelectionHandoff.State.WORKING, coordinator.state.value)
            ack.complete(Result.success(true)); job.join()
            assertEquals(ProfileSelectionHandoff.State.COMPLETE, coordinator.state.value)
        }
    }

    @Test fun `needs sign-in uses request-bound form and completes on accepted sign-in`() = runBlocking {
        val transport = Transport().apply { complete = { Result.success(false) } }
        val coordinator = ProfileSelectionHandoff(transport, native = false)
        val selection = request(ProfileStore.SwitchOutcome.NeedsSignIn)
        coordinator.select(selection)
        assertEquals(ProfileSelectionHandoff.State.SIGN_IN, coordinator.state.value)
        assertTrue(coordinator.signIn(selection, "viewer@example.com", "synthetic-password").isSuccess)
        assertEquals(ProfileSelectionHandoff.State.COMPLETE, coordinator.state.value)
    }

    @Test fun `failed token keeps profile gate closed and offers real sign-in`() = runBlocking {
        val transport = Transport().apply { complete = { Result.failure(IllegalStateException("expired synthetic credential")) } }
        val coordinator = ProfileSelectionHandoff(transport, native = false)
        val selection = request(ProfileStore.SwitchOutcome.SwitchAccount("synthetic-token"))
        coordinator.select(selection)
        assertEquals(ProfileSelectionHandoff.State.FAILED, coordinator.state.value)
        assertTrue(coordinator.signIn(selection, "viewer@example.com", "synthetic-password").isSuccess)
        assertEquals(ProfileSelectionHandoff.State.COMPLETE, coordinator.state.value)
    }

    @Test fun `failed sign-in never dismisses or exposes transport diagnostics`() = runBlocking {
        val transport = Transport().apply {
            complete = { Result.success(false) }
            login = { Result.failure(IllegalStateException("sensitive transport response")) }
        }
        val coordinator = ProfileSelectionHandoff(transport, native = false)
        val selection = request(ProfileStore.SwitchOutcome.NeedsSignIn)
        coordinator.select(selection)
        val result = coordinator.signIn(selection, "viewer@example.com", "synthetic-password")
        assertTrue(result.isFailure)
        assertFalse(result.exceptionOrNull()!!.message!!.contains("sensitive"))
        assertEquals(ProfileSelectionHandoff.State.SIGN_IN, coordinator.state.value)
    }

    @Test fun `profile A B A cannot accept the first pending reply`() = runBlocking {
        var revision = 0
        val captured = revision
        val transport = Transport().apply { complete = { revision++; revision++; Result.success(true) } }
        val coordinator = ProfileSelectionHandoff(transport, native = false)
        coordinator.select(request(ProfileStore.SwitchOutcome.SwitchAccount("synthetic-token")) { revision == captured })
        assertEquals(ProfileSelectionHandoff.State.FAILED, coordinator.state.value)
    }

    @Test fun `stale roster cannot dispatch auth or complete a later sign-in`() = runBlocking {
        var current = false
        val transport = Transport()
        val coordinator = ProfileSelectionHandoff(transport, native = false)
        coordinator.select(request(ProfileStore.SwitchOutcome.NeedsSignIn) { current })
        assertEquals(0, transport.calls)
        current = true
        transport.complete = { Result.success(false) }
        val selection = request(ProfileStore.SwitchOutcome.NeedsSignIn) { current }
        coordinator.select(selection)
        transport.login = { current = false; Result.success(Unit) }
        assertTrue(coordinator.signIn(selection, "viewer@example.com", "synthetic-password").isFailure)
        assertEquals(ProfileSelectionHandoff.State.FAILED, coordinator.state.value)
    }

    @Test fun `cancellation propagates instead of becoming success or error`() = runBlocking {
        val transport = Transport().apply { complete = { throw CancellationException("cancel") } }
        val coordinator = ProfileSelectionHandoff(transport, native = false)
        try {
            coordinator.select(request(ProfileStore.SwitchOutcome.NeedsSignIn))
            fail("Cancellation was swallowed")
        } catch (_: CancellationException) { }
        assertEquals(ProfileSelectionHandoff.State.WORKING, coordinator.state.value)
    }
}
