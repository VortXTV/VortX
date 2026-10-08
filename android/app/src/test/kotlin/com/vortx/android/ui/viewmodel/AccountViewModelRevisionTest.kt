package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModelStore
import com.vortx.android.data.AuthManagement
import com.vortx.android.data.AuthRepository
import com.vortx.android.model.AuthState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AccountViewModelRevisionTest {
    @Test fun `native account revision clears form secrets and stale operation cannot publish errors`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val done = CompletableDeferred<Unit>(); val models = ViewModelStore(); var received: String? = null
        val auth = object : AuthRepository {
            override val authState = MutableStateFlow<AuthState>(AuthState.SignedOut)
            override val management = MutableStateFlow(AuthManagement(revision = "account-a"))
            override suspend fun signIn(email: String, password: String) = error("Uncaptured call")
            override suspend fun signInForRevision(email: String, password: String, revision: String?): Result<Unit> {
                assertEquals("fake-password", password); received = revision; done.await()
                return Result.failure(IllegalStateException("stale error"))
            }
            override suspend fun signOut() = Unit
        }
        try {
            val model = AccountViewModel(auth).also { models.put("account", it) }
            model.onEmailChange("fake@example.invalid"); model.onPasswordChange("fake-password"); model.signIn()
            assertEquals("account-a", received); assertEquals("", model.password.value)
            auth.management.value = AuthManagement(revision = "account-b")
            assertEquals("", model.email.value); assertEquals("", model.password.value)
            done.complete(Unit)
            assertEquals(SignInFormState.Idle, model.formState.value)
        } finally { models.clear(); Dispatchers.resetMain() }
    }

    @Test fun `read-only child controls never call credential mutations`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler)); val models = ViewModelStore()
        var calls = 0
        val auth = object : AuthRepository {
            override val authState = MutableStateFlow<AuthState>(AuthState.SignedIn(null, "owner"))
            override val management = MutableStateFlow(AuthManagement(false, "Open Main", "child"))
            override suspend fun signIn(email: String, password: String): Result<Unit> { calls++; return Result.success(Unit) }
            override suspend fun signOut() { calls++ }
        }
        try {
            val model = AccountViewModel(auth).also { models.put("account", it) }
            model.onEmailChange("fake@example.invalid"); model.onPasswordChange("fake-password")
            model.signIn(); model.signOut(); assertEquals(0, calls)
        } finally { models.clear(); Dispatchers.resetMain() }
    }

    @Test fun `late successful signout from old revision cannot clear a newer submitting form`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler)); val models = ViewModelStore()
        val signout = CompletableDeferred<Unit>(); val signin = CompletableDeferred<Unit>()
        val auth = object : AuthRepository {
            override val authState = MutableStateFlow<AuthState>(AuthState.SignedIn(null, "a"))
            override val management = MutableStateFlow(AuthManagement(revision = "a"))
            override suspend fun signIn(email: String, password: String): Result<Unit> { signin.await(); return Result.success(Unit) }
            override suspend fun signOut() { signout.await() }
        }
        try {
            val model = AccountViewModel(auth).also { models.put("account", it) }
            model.signOut()
            auth.management.value = AuthManagement(revision = "b")
            model.onEmailChange("fake@example.invalid"); model.onPasswordChange("fake-password"); model.signIn()
            assertEquals(SignInFormState.Submitting, model.formState.value)
            signout.complete(Unit)
            assertEquals(SignInFormState.Submitting, model.formState.value)
            signin.complete(Unit); assertEquals(SignInFormState.Idle, model.formState.value)
        } finally { models.clear(); Dispatchers.resetMain() }
    }
}
