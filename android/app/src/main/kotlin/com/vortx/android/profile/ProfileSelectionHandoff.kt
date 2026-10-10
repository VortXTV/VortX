package com.vortx.android.profile

import com.vortx.android.data.AuthRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The same completion rule for cold pickers and Settings selection on both form factors. */
internal class ProfileSelectionHandoff(private val auth: AuthRepository, private val native: Boolean) {
    val canSignIn: Boolean get() = !native
    enum class State { WORKING, SIGN_IN, FAILED, COMPLETE }
    private val mutableState = MutableStateFlow(State.WORKING)
    val state = mutableState.asStateFlow()
    private var active: ProfileSelectionRequest? = null

    fun complete(request: ProfileSelectionRequest): Boolean = try {
        check(active === request && mutableState.value == State.COMPLETE)
        request.complete()
        true
    } catch (_: Exception) { mutableState.value = State.FAILED; false }

    suspend fun select(request: ProfileSelectionRequest) {
        active = request
        mutableState.value = State.WORKING
        try {
            request.requireCurrent()
            val complete = if (native) {
                check(request.outcome == ProfileStore.SwitchOutcome.SameAccount)
                true
            } else auth.completeProfileSelection(request).getOrThrow()
            request.requireCurrent()
            if (active === request) mutableState.value = if (complete) State.COMPLETE else State.SIGN_IN
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { if (active === request) mutableState.value = State.FAILED }
    }

    suspend fun signIn(request: ProfileSelectionRequest, email: String, password: String): Result<Unit> {
        try {
            request.requireCurrent()
            check(active === request && !native)
            val result = auth.signInForProfileSelection(request, email, password)
            request.requireCurrent()
            check(active === request)
            if (result.isSuccess) mutableState.value = State.COMPLETE
            // The form receives useful plain copy, never arbitrary transport diagnostics or tokens.
            return if (result.isSuccess) result else Result.failure(IllegalStateException(
                "Sign-in could not be confirmed for this profile. Check the account and try again."))
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) {
            if (active === request) mutableState.value = State.FAILED
            return Result.failure(IllegalStateException("The profile changed. Choose it again."))
        }
    }
}
