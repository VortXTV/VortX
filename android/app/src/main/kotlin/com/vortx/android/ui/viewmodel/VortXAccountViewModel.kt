package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/// Which auth flow the signed-out form is showing. All three land in the same signed-in state.
enum class VortXAccountMode { SIGN_IN, REGISTER, RECOVER }

/// One-way UI state for the VortX-account FORM (same shape as [SignInFormState] on the Stremio
/// account screen): idle, submitting, or a surfaced inline error string -- never a modal/alert
/// (DESIGN-SYSTEM.md §7 anti-pattern "no `window.alert`-style interruption").
sealed interface VortXAccountFormState {
    data object Idle : VortXAccountFormState
    data object Submitting : VortXAccountFormState
    data class Error(val message: String) : VortXAccountFormState
}

/// Drives the VortX account screen against the app-wide [VortXSyncManager] -- the E2E-encrypted
/// VortX account (NOT the engine's Stremio [com.vortx.android.data.AuthRepository], which keeps its
/// own screen). This is the seam the audit flagged missing: the manager's register / signIn /
/// recover / reconcileAfterSignIn / syncUp / syncDown were fully built but nothing in `ui/` called
/// them, so `isSignedIn` could never become true and every sync early-returned.
///
/// Post-auth sequencing enforces the #145 restore-before-push order: reconcile FIRST (a fresh
/// account seeds from this device; an account WITH data asks which side to keep; an unreachable doc
/// pushes NOTHING), and the realtime channel starts only once that question is settled, so its
/// catch-up pull can never pre-empt the user's "keep this device" choice. Secrets hygiene: the
/// password / TOTP / recovery-code fields are cleared the moment a flow completes, and nothing here
/// logs -- the token and data key never leave the sync package.
class VortXAccountViewModel(private val sync: VortXSyncManager) : ViewModel() {

    /// The signed-in VortX account (null when signed out), straight off the manager -- no local
    /// "am I signed in" flag, so a session restored at process start reflects immediately.
    val account: StateFlow<VortXSyncManager.Account?> = sync.account

    private val _mode = MutableStateFlow(VortXAccountMode.SIGN_IN)
    val mode: StateFlow<VortXAccountMode> = _mode.asStateFlow()

    // Form fields. [login] is email-or-username on sign-in and the email on register/recover;
    // [username] is register-only; [password] doubles as the NEW password on recover.
    private val _login = MutableStateFlow("")
    val login: StateFlow<String> = _login.asStateFlow()

    private val _username = MutableStateFlow("")
    val username: StateFlow<String> = _username.asStateFlow()

    private val _password = MutableStateFlow("")
    val password: StateFlow<String> = _password.asStateFlow()

    private val _totp = MutableStateFlow("")
    val totp: StateFlow<String> = _totp.asStateFlow()

    private val _recoveryInput = MutableStateFlow("")
    val recoveryInput: StateFlow<String> = _recoveryInput.asStateFlow()

    private val _formState = MutableStateFlow<VortXAccountFormState>(VortXAccountFormState.Idle)
    val formState: StateFlow<VortXAccountFormState> = _formState.asStateFlow()

    /// True once sign-in answered TotpRequired: the form reveals the 6-digit field and resubmits with it.
    private val _totpRequired = MutableStateFlow(false)
    val totpRequired: StateFlow<Boolean> = _totpRequired.asStateFlow()

    /// The one-time recovery code returned by register. Shown ONCE (with the store-it-offline
    /// warning) until the user confirms they saved it; never persisted anywhere by the app.
    private val _recoveryCode = MutableStateFlow<String?>(null)
    val recoveryCode: StateFlow<String?> = _recoveryCode.asStateFlow()

    /// True while the sign-in reconcile question ("this account already has data -- keep which
    /// side?") is waiting on the user. While true the screen shows the choice card, nothing pushes.
    private val _showReconcile = MutableStateFlow(false)
    val showReconcile: StateFlow<Boolean> = _showReconcile.asStateFlow()

    /// A manual sync (or a reconcile choice) is in flight -- drives the Sync-now button's spinner.
    private val _syncing = MutableStateFlow(false)
    val syncing: StateFlow<Boolean> = _syncing.asStateFlow()

    /// One-line, non-blocking status under the signed-in card ("Synced." / "Couldn't reach...").
    private val _syncNotice = MutableStateFlow<String?>(null)
    val syncNotice: StateFlow<String?> = _syncNotice.asStateFlow()

    fun onModeChange(mode: VortXAccountMode) {
        if (_mode.value == mode) return
        _mode.value = mode
        _formState.value = VortXAccountFormState.Idle
        _totpRequired.value = false
        _totp.value = ""
    }

    fun onLoginChange(value: String) { _login.value = value }
    fun onUsernameChange(value: String) { _username.value = value }
    fun onPasswordChange(value: String) { _password.value = value }
    fun onTotpChange(value: String) { _totp.value = value }
    fun onRecoveryInputChange(value: String) { _recoveryInput.value = value }

    /// Submit whichever flow [mode] is showing. One submit in flight at a time.
    fun submit() {
        if (_formState.value == VortXAccountFormState.Submitting) return
        val error = validate()
        if (error != null) {
            _formState.value = VortXAccountFormState.Error(error)
            return
        }
        _formState.value = VortXAccountFormState.Submitting
        viewModelScope.launch {
            when (_mode.value) {
                VortXAccountMode.SIGN_IN -> signIn()
                VortXAccountMode.REGISTER -> register()
                VortXAccountMode.RECOVER -> recover()
            }
        }
    }

    /// Fail fast at the boundary with a clear message, before any network or key derivation runs.
    private fun validate(): String? {
        val mode = _mode.value
        if (_login.value.isBlank()) {
            return if (mode == VortXAccountMode.SIGN_IN) "Enter your email or username." else "Enter your email."
        }
        if (mode != VortXAccountMode.SIGN_IN && !_login.value.contains("@")) return "Enter a valid email."
        if (mode == VortXAccountMode.REGISTER && _username.value.isBlank()) return "Pick a username."
        if (_password.value.isEmpty()) {
            return if (mode == VortXAccountMode.RECOVER) "Enter a new password." else "Enter your password."
        }
        if (mode != VortXAccountMode.SIGN_IN && _password.value.length < MIN_PASSWORD_LENGTH) {
            return "Use at least $MIN_PASSWORD_LENGTH characters."
        }
        if (mode == VortXAccountMode.RECOVER && _recoveryInput.value.isBlank()) return "Enter your recovery code."
        return null
    }

    private suspend fun signIn() {
        val code = _totp.value.trim().takeIf { it.isNotEmpty() }
        when (val result = sync.signIn(_login.value.trim(), _password.value, code)) {
            VortXSyncManager.AuthResult.Ok -> onAuthed()
            VortXSyncManager.AuthResult.TotpRequired -> {
                // First time: reveal the 6-digit field. With a code already supplied it was wrong.
                _formState.value = if (code == null) {
                    VortXAccountFormState.Idle
                } else {
                    VortXAccountFormState.Error("That code didn't work. Try again.")
                }
                _totpRequired.value = true
            }
            is VortXSyncManager.AuthResult.Failed -> _formState.value = VortXAccountFormState.Error(result.message)
        }
    }

    private suspend fun register() {
        val result = sync.register(_login.value.trim(), _username.value.trim(), _password.value)
        when (val auth = result.result) {
            VortXSyncManager.AuthResult.Ok -> {
                _recoveryCode.value = result.recoveryCode   // shown once, on the signed-in screen
                onAuthed()
            }
            is VortXSyncManager.AuthResult.Failed -> _formState.value = VortXAccountFormState.Error(auth.message)
            VortXSyncManager.AuthResult.TotpRequired -> // register never asks for TOTP; treat as failure
                _formState.value = VortXAccountFormState.Error("Could not create the account.")
        }
    }

    private suspend fun recover() {
        when (val result = sync.recover(_login.value.trim(), _recoveryInput.value, _password.value)) {
            VortXSyncManager.AuthResult.Ok -> onAuthed()
            is VortXSyncManager.AuthResult.Failed -> _formState.value = VortXAccountFormState.Error(result.message)
            VortXSyncManager.AuthResult.TotpRequired -> // recover never asks for TOTP; treat as failure
                _formState.value = VortXAccountFormState.Error("Recovery failed.")
        }
    }

    /**
     * Shared post-auth path. Clears every secret out of form state, then runs the manager's sign-in
     * reconciliation BEFORE any push or realtime start (#145 restore-before-push):
     *  - SEEDED_FROM_DEVICE: fresh/empty account, the manager already seeded it from this device.
     *  - HAS_ACCOUNT_DATA: the account holds synced data; ask the user which side to keep and start
     *    NOTHING until they answer (so no pull pre-empts a "keep this device" choice).
     *  - UNREACHABLE: pushed nothing (a blip is never treated as a fresh account); realtime's guarded
     *    catch-up pull + poll retry until the doc is reachable.
     */
    private suspend fun onAuthed() {
        _password.value = ""
        _totp.value = ""
        _recoveryInput.value = ""
        _totpRequired.value = false
        _formState.value = VortXAccountFormState.Idle
        when (sync.reconcileAfterSignIn()) {
            VortXSyncManager.SignInReconcile.SEEDED_FROM_DEVICE -> {
                _syncNotice.value = null
                sync.startRealtime()
            }
            VortXSyncManager.SignInReconcile.HAS_ACCOUNT_DATA -> _showReconcile.value = true
            VortXSyncManager.SignInReconcile.UNREACHABLE -> {
                _syncNotice.value = "Signed in. Your synced data wasn't reachable yet; it will catch up automatically."
                sync.startRealtime()
            }
        }
    }

    // ---- Reconcile choices (all still union/tombstone-safe inside the manager) ----

    /// Recommended: union both ways so every profile from both sides survives, then push.
    fun reconcileMergeBoth() = resolveReconcile { sync.mergeBoth() }

    /// Adopt the account's data (a forced pull; still a union, so no local-only profile is lost).
    fun reconcileUseAccount() = resolveReconcile { sync.useAccountData() }

    /// Keep this device's data (a push; still merged into the pulled doc, never a blind overwrite).
    fun reconcileKeepDevice() = resolveReconcile { sync.pushThisDevice() }

    private fun resolveReconcile(action: suspend () -> Unit) {
        _showReconcile.value = false
        viewModelScope.launch {
            _syncing.value = true
            action()
            _syncing.value = false
            sync.startRealtime()   // the question is settled; open the live channel
        }
    }

    // ---- Signed-in actions ----

    /// Manual "Sync now": the documented recommended path (union both ways, then push).
    fun syncNow() {
        if (_syncing.value) return
        _syncing.value = true
        viewModelScope.launch {
            val pushed = sync.mergeBoth()
            _syncNotice.value = if (pushed) "Synced." else "Couldn't sync right now. It will retry automatically."
            _syncing.value = false
        }
    }

    /// The user confirmed they stored the one-time recovery code; it is never shown again.
    fun dismissRecoveryCode() {
        _recoveryCode.value = null
    }

    fun signOut() {
        sync.signOut()             // stops realtime + clears the persisted session inside the manager
        _showReconcile.value = false
        _recoveryCode.value = null
        _syncNotice.value = null
        _mode.value = VortXAccountMode.SIGN_IN
        _formState.value = VortXAccountFormState.Idle
    }

    private companion object {
        /// Floor for a NEW password (register/recover). Sign-in never gates: existing accounts rule.
        const val MIN_PASSWORD_LENGTH = 8
    }
}
