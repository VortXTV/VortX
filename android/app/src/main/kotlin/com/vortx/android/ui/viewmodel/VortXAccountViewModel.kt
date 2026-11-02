package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.PickerAuthCompletion
import com.vortx.android.sync.PickerSignOutResult
import com.vortx.android.sync.runPickerSignOut
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.URLEncoder

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

sealed interface VortXQrJoinState {
    data object Idle : VortXQrJoinState
    data object Starting : VortXQrJoinState
    data class Waiting(
        val code: String,
        val approvalUrl: String,
        val reachTrouble: Boolean,
    ) : VortXQrJoinState
    data class SignedIn(val email: String) : VortXQrJoinState
    data object Failed : VortXQrJoinState
}

internal sealed interface QrJoinerAction {
    data class KeepWaiting(val reachTrouble: Boolean) : QrJoinerAction
    data object Remint : QrJoinerAction
    data class SignedIn(val email: String) : QrJoinerAction
    data object Failed : QrJoinerAction
}

internal class QrJoinerReducer(
    private val errorNoticeThreshold: Int = 4,
    private val codeMaxAgeMs: Long = 240_000L,
) {
    private var consecutiveErrors = 0

    fun onResult(result: VortXSyncManager.QrJoinResult, codeAgeMs: Long): QrJoinerAction = when (result) {
        is VortXSyncManager.QrJoinResult.SignedIn -> QrJoinerAction.SignedIn(result.email)
        VortXSyncManager.QrJoinResult.Failed -> QrJoinerAction.Failed
        VortXSyncManager.QrJoinResult.Expired -> {
            consecutiveErrors = 0
            QrJoinerAction.Remint
        }
        VortXSyncManager.QrJoinResult.TransportError -> {
            consecutiveErrors += 1
            QrJoinerAction.KeepWaiting(consecutiveErrors >= errorNoticeThreshold)
        }
        VortXSyncManager.QrJoinResult.Pending -> {
            consecutiveErrors = 0
            if (codeAgeMs >= codeMaxAgeMs) QrJoinerAction.Remint else QrJoinerAction.KeepWaiting(false)
        }
    }
}

internal fun vortxApprovalUrl(code: String, devicePublicKey: String): String =
    "https://vortx.tv/approve?c=${urlEncode(code.trim().uppercase())}&k=${urlEncode(devicePublicKey)}"

private fun urlEncode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name())

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

    /** Persistence truth for rendering unavailable separately from a definitive signed-out session. */
    val sessionUiState: StateFlow<VortXSyncManager.SessionUiState> = sync.sessionUiState

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

    private val _qrJoinState = MutableStateFlow<VortXQrJoinState>(VortXQrJoinState.Idle)
    val qrJoinState: StateFlow<VortXQrJoinState> = _qrJoinState.asStateFlow()
    private var qrJoinJob: Job? = null

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

    // Form cleanup identity is independent of request completion and account authority.
    // Editing A -> B -> A revokes old cleanup, without enabling a second concurrent submit.
    private var authFormIdentity = Any()
    private var activeAuthSubmission: Any? = null
    private var authSubmissionJob: Job? = null
    private var completionOwner: PickerAccountSnapshot? = null
    private val _postAuthCompleting = MutableStateFlow(false)
    internal val postAuthCompleting: StateFlow<Boolean> = _postAuthCompleting.asStateFlow()
    private val _pickerPresentationOpen = MutableStateFlow(false)
    internal val pickerPresentationOpen: StateFlow<Boolean> = _pickerPresentationOpen.asStateFlow()
    private val _pickerDismissalNotice = MutableStateFlow<String?>(null)
    internal val pickerDismissalNotice: StateFlow<String?> = _pickerDismissalNotice.asStateFlow()

    private fun clearPendingCompletion() {
        completionOwner = null
        _postAuthCompleting.value = false
        _recoveryCode.value = null
        _showReconcile.value = false
        _pickerDismissalNotice.value = null
    }
    private fun settleCompletionIfFinished() {
        if (!_postAuthCompleting.value && _recoveryCode.value == null && !_showReconcile.value) completionOwner = null
    }
    private fun retireObsoleteCompletion() {
        val owner = completionOwner ?: return
        if (!sync.isPickerCompletionOwnerCurrent(owner)) {
            clearPendingCompletion()
            invalidateAuthForm(); authSubmissionJob?.cancel(); stopQrJoiner(); clearAuthInputs()
            _pickerPresentationOpen.value = false
        }
    }
    internal fun hasPendingPickerCompletion(): Boolean {
        retireObsoleteCompletion()
        return completionOwner != null && (_postAuthCompleting.value || _recoveryCode.value != null || _showReconcile.value)
    }
    internal fun openPickerPresentation() {
        retireObsoleteCompletion(); _pickerDismissalNotice.value = null
        _pickerPresentationOpen.value = true
    }
    internal fun requestClosePickerPresentation(): Boolean {
        if (authSubmissionJob?.isActive == true && activeAuthSubmission != null) {
            _pickerDismissalNotice.value = "Wait for the current account request to finish before returning to profiles."
            return false
        }
        if (hasPendingPickerCompletion()) {
            _pickerDismissalNotice.value = if (_recoveryCode.value != null)
                "Save your recovery code and finish account setup before returning to profiles."
                else "Finish account setup before returning to profiles."
            return false
        }
        _pickerPresentationOpen.value = false
        invalidateAuthForm(); authSubmissionJob?.cancel(); stopQrJoiner(); clearAuthInputs()
        return true
    }
    internal fun retirePickerPresentationForSignOut() {
        _pickerPresentationOpen.value = false
        invalidateAuthForm(); stopQrJoiner()
        if (!hasPendingPickerCompletion()) { authSubmissionJob?.cancel(); clearAuthInputs() }
    }
    internal fun resumePickerCompletionIfCurrent() {
        if (hasPendingPickerCompletion()) _pickerPresentationOpen.value = true
    }
    internal fun requireAccountReconcile() = requireAccountReconcile(sync.capturePickerCompletionOwner())
    private fun requireAccountReconcile(owner: PickerAccountSnapshot) {
        retireObsoleteCompletion()
        sync.publishIfPickerCompletionOwnerCurrent(owner) {
            completionOwner = owner; _showReconcile.value = true
        }
    }

    private fun invalidateAuthForm() {
        authFormIdentity = Any()
    }

    init {
        viewModelScope.launch { sync.pickerAccountRevision.collect { retireObsoleteCompletion() } }
        viewModelScope.launch { sync.sessionUiState.collect { retireObsoleteCompletion() } }
        viewModelScope.launch {
            sync.syncProblem.collect { problem -> _syncNotice.value = problem }
        }
    }

    fun onModeChange(mode: VortXAccountMode) {
        if (_mode.value == mode) return
        invalidateAuthForm()
        _mode.value = mode
        _formState.value = VortXAccountFormState.Idle
        _totpRequired.value = false
        _totp.value = ""
        if (mode != VortXAccountMode.SIGN_IN) stopQrJoiner()
    }

    fun onLoginChange(value: String) { invalidateAuthForm(); _login.value = value }
    fun onUsernameChange(value: String) { invalidateAuthForm(); _username.value = value }
    fun onPasswordChange(value: String) { invalidateAuthForm(); _password.value = value }
    fun onTotpChange(value: String) { invalidateAuthForm(); _totp.value = value }
    fun onRecoveryInputChange(value: String) { invalidateAuthForm(); _recoveryInput.value = value }

    fun retrySessionRestore() {
        sync.retrySessionRestore()
    }

    fun startQrJoiner() {
        if (qrJoinJob?.isActive == true || account.value != null) return
        qrJoinJob = viewModelScope.launch { runQrJoiner() }
    }

    fun retryQrJoiner() {
        stopQrJoiner()
        startQrJoiner()
    }

    fun stopQrJoiner() {
        qrJoinJob?.cancel()
        qrJoinJob = null
        if (_qrJoinState.value !is VortXQrJoinState.SignedIn) {
            _qrJoinState.value = VortXQrJoinState.Idle
        }
    }

    private suspend fun runQrJoiner() {
        while (currentCoroutineContext().isActive) {
            _qrJoinState.value = VortXQrJoinState.Starting
            val session = sync.qrStart()
            if (session == null) {
                _qrJoinState.value = VortXQrJoinState.Failed
                return
            }
            val mintedAt = System.currentTimeMillis()
            val reducer = QrJoinerReducer()
            val approvalUrl = vortxApprovalUrl(session.code, session.devicePublicKey)
            _qrJoinState.value = VortXQrJoinState.Waiting(session.code, approvalUrl, false)

            var remint = false
            while (currentCoroutineContext().isActive && !remint) {
                delay(QR_POLL_INTERVAL_MS)
                val completion = PickerAuthCompletion()
                when (
                    val action = reducer.onResult(
                        sync.qrPoll(session, completion),
                        System.currentTimeMillis() - mintedAt,
                    )
                ) {
                    is QrJoinerAction.KeepWaiting ->
                        _qrJoinState.value = VortXQrJoinState.Waiting(
                            session.code,
                            approvalUrl,
                            action.reachTrouble,
                        )
                    QrJoinerAction.Remint -> remint = true
                    QrJoinerAction.Failed -> {
                        _qrJoinState.value = VortXQrJoinState.Failed
                        return
                    }
                    is QrJoinerAction.SignedIn -> {
                        // Adoption updates sessionUiState immediately, which removes this QR composable.
                        // Detach the current job first so its onDispose does not cancel reconciliation.
                        qrJoinJob = null
                        _qrJoinState.value = VortXQrJoinState.SignedIn(action.email)
                        onQrAuthed(completion.owner)
                        return
                    }
                }
            }
        }
    }

    /// Submit whichever flow [mode] is showing. One submit in flight at a time.
    fun submit() {
        if (_formState.value == VortXAccountFormState.Submitting) return
        val error = validate()
        if (error != null) {
            _formState.value = VortXAccountFormState.Error(error)
            return
        }
        stopQrJoiner()
        val identity = Any()
        val submittedMode = _mode.value
        val admission = sync.captureLocalLibraryMutationAdmission()
        authFormIdentity = identity
        activeAuthSubmission = identity
        _formState.value = VortXAccountFormState.Submitting
        authSubmissionJob = viewModelScope.launch {
            try {
                if (authFormIdentity !== identity) return@launch
                when (submittedMode) {
                    VortXAccountMode.SIGN_IN -> signIn()
                    VortXAccountMode.REGISTER -> register()
                    VortXAccountMode.RECOVER -> recover()
                }
            } catch (cancel: CancellationException) {
                if (authFormIdentity === identity) clearAuthInputs()
                throw cancel
            } catch (_: Exception) {
                // Adoption revokes the old account admission, but must not leave its own
                // original secrets live. Never clear fields belonging to an edited form.
                if (authFormIdentity === identity) clearAuthInputs()
                admission?.invoke {
                    if (authFormIdentity === identity) {
                        _formState.value = VortXAccountFormState.Error(AUTH_RETRY_NOTICE)
                    }
                    true
                }
            } finally {
                // An edit still waits for this request, while a mode-change/new submission
                // can already own another spinner. Neither completion clears replacement input.
                if (activeAuthSubmission === identity) {
                    activeAuthSubmission = null
                    if (_formState.value == VortXAccountFormState.Submitting) _formState.value = VortXAccountFormState.Idle
                }
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
        val completion = PickerAuthCompletion()
        when (val result = sync.signIn(_login.value.trim(), _password.value, code, completion)) {
            VortXSyncManager.AuthResult.Ok -> onAuthed(completion.owner)
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
        val original = sync.capturePickerCompletionOwner()
        val completion = PickerAuthCompletion()
        completeRegistration(sync.register(_login.value.trim(), _username.value.trim(), _password.value, completion), original, completion.owner)
    }
    /** Actual registration-result publication, shared with bounded post-adoption lifecycle fixtures. */
    internal suspend fun completeRegistration(result: VortXSyncManager.RegisterResult, original: PickerAccountSnapshot, adoptedOwner: PickerAccountSnapshot?) {
        retireObsoleteCompletion()
        val owner = if (result.result == VortXSyncManager.AuthResult.Ok) adoptedOwner else original
        result.recoveryCode?.let { code ->
            if (owner != null) sync.publishIfPickerCompletionOwnerCurrent(owner) {
                completionOwner = owner; _recoveryCode.value = code; _password.value = ""
            }
        }
        when (val auth = result.result) {
            VortXSyncManager.AuthResult.Ok -> onAuthed(owner)
            is VortXSyncManager.AuthResult.Failed -> {
                if (result.recoveryCode != null) _mode.value = VortXAccountMode.SIGN_IN
                _formState.value = VortXAccountFormState.Error(auth.message)
            }
            VortXSyncManager.AuthResult.TotpRequired -> // register never asks for TOTP; treat as failure
                _formState.value = VortXAccountFormState.Error("Could not create the account.")
        }
    }

    private suspend fun recover() {
        val completion = PickerAuthCompletion()
        when (val result = sync.recover(_login.value.trim(), _recoveryInput.value, _password.value, completion)) {
            VortXSyncManager.AuthResult.Ok -> onAuthed(completion.owner)
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
    private suspend fun onAuthed(owner: PickerAccountSnapshot?) = finishPostAuth(owner) {
        val original = checkNotNull(owner)
        when (sync.reconcileAfterSignIn(original)) {
            VortXSyncManager.SignInReconcile.SEEDED_FROM_DEVICE -> publishCompletion(original) {
                _syncNotice.value = null; sync.startRealtime()
            }
            VortXSyncManager.SignInReconcile.HAS_ACCOUNT_DATA -> requireAccountReconcile(original)
            VortXSyncManager.SignInReconcile.UNREACHABLE -> publishCompletion(original) {
                _syncNotice.value = sync.syncProblem.value ?: "Signed in. Your synced data wasn't reachable yet; it will catch up automatically."
                sync.startRealtime()
            }
        }
    }
    private fun publishCompletion(owner: PickerAccountSnapshot, publication: () -> Unit) {
        sync.publishIfPickerCompletionOwnerCurrent(owner, publication)
    }
    /** QR uses the exact adoption receipt rather than adopting a later current session. */
    private suspend fun onQrAuthed(owner: PickerAccountSnapshot?) = finishPostAuth(owner) {
        val original = checkNotNull(owner)
        when (sync.reconcileAfterSignIn(original)) {
            VortXSyncManager.SignInReconcile.SEEDED_FROM_DEVICE -> publishCompletion(original) { _syncNotice.value = null }
            VortXSyncManager.SignInReconcile.HAS_ACCOUNT_DATA -> {
                val restored = sync.useAccountData(original)
                publishCompletion(original) { if (!restored) _syncNotice.value = sync.syncProblem.value
                    ?: "Signed in. Your saved data is preserved, but the account restore could not finish yet. Try Sync now again." }
            }
            VortXSyncManager.SignInReconcile.UNREACHABLE -> publishCompletion(original) {
                _syncNotice.value = sync.syncProblem.value ?: "Signed in. Your synced data wasn't reachable yet; it will catch up automatically."
            }
        }
        publishCompletion(original) { sync.startRealtime() }
    }

    /** Shared signed-in completion boundary: a failed restore must not discard the saved session. */
    internal suspend fun finishPostAuth(action: suspend () -> Unit) = finishPostAuth(sync.capturePickerCompletionOwner(), action)
    private suspend fun finishPostAuth(owner: PickerAccountSnapshot?, action: suspend () -> Unit) {
        retireObsoleteCompletion()
        clearAuthInputs()
        if (owner == null || !sync.isPickerCompletionOwnerCurrent(owner)) return
        completionOwner = owner; _postAuthCompleting.value = true
        val admit = sync.captureLocalLibraryMutationAdmission()
        try {
            action()
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) {
            admit?.invoke { _syncNotice.value = POST_AUTH_RETRY_NOTICE; true }
        } finally {
            if (completionOwner === owner) { _postAuthCompleting.value = false; settleCompletionIfFinished() }
            retireObsoleteCompletion()
        }
    }

    private fun clearAuthInputs() {
        _password.value = ""
        _totp.value = ""
        _recoveryInput.value = ""
        _totpRequired.value = false
        _formState.value = VortXAccountFormState.Idle
    }

    // ---- Reconcile choices (all still union/tombstone-safe inside the manager) ----

    /// Recommended: union both ways so every profile from both sides survives, then push.
    fun reconcileMergeBoth() = resolveReconcile { owner -> sync.mergeBoth(owner) }

    /// Adopt the account's data (a forced pull; still a union, so no local-only profile is lost).
    fun reconcileUseAccount() = resolveReconcile { owner -> sync.useAccountData(owner) }

    /// Keep this device's data (a push; still merged into the pulled doc, never a blind overwrite).
    fun reconcileKeepDevice() = resolveReconcile { owner -> sync.importThisDeviceLibraryAndPush(owner) }

    private fun resolveReconcile(action: suspend (PickerAccountSnapshot) -> Boolean) {
        retireObsoleteCompletion()
        val owner = completionOwner ?: return
        if (_syncing.value || !_showReconcile.value) return
        // Reuse invocation ownership so a delayed choice cannot publish into a replacement session.
        val admit = sync.captureLocalLibraryMutationAdmission() ?: return
        _syncing.value = true
        _syncNotice.value = null
        viewModelScope.launch {
            try {
                val reconciled = action(owner)
                admit {
                    if (_showReconcile.value) {
                        if (reconciled) {
                            _showReconcile.value = false
                            settleCompletionIfFinished()
                            _syncNotice.value = null
                            sync.startRealtime() // Only a confirmed choice settles reconciliation.
                        } else {
                            _syncNotice.value = sync.syncProblem.value ?: RECONCILE_RETRY_NOTICE
                        }
                    }
                    true
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                admit {
                    if (_showReconcile.value) _syncNotice.value = sync.syncProblem.value ?: RECONCILE_RETRY_NOTICE
                    true
                }
            } finally { _syncing.value = false }
        }
    }

    // ---- Signed-in actions ----

    /// Manual "Sync now": the documented recommended path (union both ways, then push).
    fun syncNow() {
        if (_syncing.value) return
        _syncing.value = true
        val admit = sync.captureLocalLibraryMutationAdmission()
        viewModelScope.launch {
            try {
                val pushed = sync.mergeBoth()
                admit?.invoke {
                    _syncNotice.value = sync.syncProblem.value ?: if (pushed) "Synced." else SYNC_RETRY_NOTICE
                    true
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                admit?.invoke { _syncNotice.value = SYNC_RETRY_NOTICE; true }
            } finally { _syncing.value = false }
        }
    }

    /// The user confirmed they stored the one-time recovery code; it is never shown again.
    fun dismissRecoveryCode(expectedCode: String? = null) {
        retireObsoleteCompletion()
        if (expectedCode != null && _recoveryCode.value != expectedCode) return
        _recoveryCode.value = null
        _pickerDismissalNotice.value = null
        settleCompletionIfFinished()
    }

    fun signOut() {
        invalidateAuthForm()
        if (!sync.signOut()) {
            _syncNotice.value =
                "Secure storage is unavailable. Your VortX session was not changed. Please try again."
            return
        }
        finishSignOutUi()
    }

    internal fun signOut(expected: PickerAccountSnapshot, retireUi: () -> Unit): PickerSignOutResult = runPickerSignOut(
        isCurrent = { sync.isPickerAccountCurrent(expected) },
        retireUi = retireUi,
        signOut = {
            invalidateAuthForm()
            sync.signOut(expected).also { result ->
                if (result == PickerSignOutResult.SIGNED_OUT) finishSignOutUi()
                else if (result == PickerSignOutResult.STORAGE_UNAVAILABLE) _syncNotice.value =
                    "Secure storage is unavailable. Your VortX session was not changed. Please try again."
            }
        },
    )

    private fun finishSignOutUi() {
        clearPendingCompletion()
        _pickerPresentationOpen.value = false
        stopQrJoiner()
        clearAuthInputs()
        _showReconcile.value = false
        _recoveryCode.value = null
        _syncNotice.value = null
        _mode.value = VortXAccountMode.SIGN_IN
        _formState.value = VortXAccountFormState.Idle
    }

    override fun onCleared() {
        clearPendingCompletion()
        invalidateAuthForm()
        clearAuthInputs()
        stopQrJoiner()
        super.onCleared()
    }

    private companion object {
        /// Floor for a NEW password (register/recover). Sign-in never gates: existing accounts rule.
        const val AUTH_RETRY_NOTICE = "Could not complete this account action. Your saved data is preserved. Please try again."
        const val POST_AUTH_RETRY_NOTICE = "Signed in. Sync could not finish. Your saved data is preserved. Try Sync now again."
        const val SYNC_RETRY_NOTICE = "Couldn't sync right now. Your saved data is preserved. Try Sync now again."
        const val RECONCILE_RETRY_NOTICE = "Couldn't finish syncing. Your saved data is preserved. Choose an option to retry."
        const val MIN_PASSWORD_LENGTH = 8
        const val QR_POLL_INTERVAL_MS = 2_000L
    }
}
