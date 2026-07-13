package com.stremiox.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.stremiox.android.data.AuthRepository
import com.stremiox.android.model.AuthState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/// One-way UI state for the sign-in FORM specifically (separate from [AuthState], which is the
/// account's actual signed-in/out truth): idle, submitting, or a surfaced error message. Mirrors
/// Apple `StremioAccount.signInError` -- a nullable, dismiss-on-retry error string next to the fields,
/// never a modal/alert (DESIGN-SYSTEM.md §7 anti-pattern "no `window.alert`-style interruption").
sealed interface SignInFormState {
    data object Idle : SignInFormState
    data object Submitting : SignInFormState
    data class Error(val message: String) : SignInFormState
}

/// Drives the account screen (Settings' Account row destination): the live [authState] from the
/// engine, the sign-in form fields + submit state, and sign-out. One instance per screen visit (like
/// every other screen ViewModel here), backed by whichever [AuthRepository] the app is running --
/// the real engine implementation in production, [com.stremiox.android.data.PreviewAuthRepository]
/// for @Previews/debug.
class AccountViewModel(private val auth: AuthRepository) : ViewModel() {

    // The repository's flow is already a (hot, conflated) StateFlow; expose it directly rather than
    // re-wrapping in stateIn, which would add a hardcoded initial value that could flash "Not signed
    // in" for a frame on a signed-in account.
    val authState: StateFlow<AuthState> = auth.authState

    private val _email = MutableStateFlow("")
    val email: StateFlow<String> = _email.asStateFlow()

    private val _password = MutableStateFlow("")
    val password: StateFlow<String> = _password.asStateFlow()

    private val _formState = MutableStateFlow<SignInFormState>(SignInFormState.Idle)
    val formState: StateFlow<SignInFormState> = _formState.asStateFlow()

    fun onEmailChange(value: String) {
        _email.value = value
    }

    fun onPasswordChange(value: String) {
        _password.value = value
    }

    fun signIn() {
        if (_formState.value == SignInFormState.Submitting) return // one submit in flight at a time
        _formState.value = SignInFormState.Submitting
        viewModelScope.launch {
            val result = auth.signIn(_email.value, _password.value)
            _formState.value = result.fold(
                onSuccess = {
                    _password.value = "" // don't leave a plaintext password sitting in form state
                    SignInFormState.Idle
                },
                onFailure = { SignInFormState.Error(it.message ?: "Sign-in failed. Try again.") },
            )
        }
    }

    fun signOut() {
        viewModelScope.launch { auth.signOut() }
    }
}
