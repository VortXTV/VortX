package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.vortx.android.engine.NativeAccountCoordinator
import com.vortx.android.engine.NativeProfileAccess
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** UI contains no credential authority: the coordinator captures the account/profile/binding
 * before the form is shown and rechecks it after every asynchronous source request. */
internal class NativeStreamingAccountViewModel(private val accounts: NativeAccountCoordinator) : ViewModel() {
    class Prepared internal constructor(internal val target: NativeAccountCoordinator.StreamingTarget) { val profile get() = target.profile }
    class Editor internal constructor(internal val target: NativeProfileAccess.EditTarget,
                                     internal val account: com.vortx.android.sync.SessionOwnerSnapshot.Account)
    private val profiles = NativeProfileAccess { accounts.session() }
    data class State(val mounted: Boolean = false, val profiles: List<UserProfile> = emptyList(), val activeID: String? = null,
                     val streaming: List<NativeAccountCoordinator.StreamingProfile> = emptyList(),
                     val formProfile: UserProfile? = null, val busy: Boolean = false, val message: String? = null)
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private var target: NativeAccountCoordinator.StreamingTarget? = null
    private var request: Job? = null

    init {
        refresh()
        viewModelScope.launch {
            accounts.changes.collectLatest {
                refresh()
                runCatching { accounts.session() }.getOrNull()?.updates?.collect { refresh() }
            }
        }
    }

    fun refresh() {
        val projection = runCatching { NativeProfileAccess.projection(accounts.session().read()) }.getOrNull()
        val streaming = runCatching { accounts.streamingProfiles() }.getOrDefault(emptyList())
        mutable.value = mutable.value.copy(mounted = projection != null,
            profiles = projection?.profiles ?: streaming.map { it.profile }, activeID = projection?.activeID, streaming = streaming)
    }
    fun prepare(profileID: String): Prepared? = runCatching { Prepared(accounts.captureStreamingTarget(profileID)) }.getOrElse {
        mutable.value = mutable.value.copy(message = "The profile changed. Open it again before signing in."); null
    }
    fun open(profileID: String) { prepare(profileID)?.let(::openPrepared) }
    fun openPrepared(prepared: Prepared) {
        if (mutable.value.busy) return
        target = null
        runCatching { accounts.requireStreamingTargetCurrent(prepared.target) }.onSuccess {
            target = prepared.target; mutable.value = mutable.value.copy(formProfile = prepared.profile, message = null)
        }.onFailure { mutable.value = mutable.value.copy(formProfile = null, message = "The profile changed. Unlock the current profile again.") }
    }
    fun captureEditor(profile: UserProfile, adding: Boolean): Editor? = runCatching {
        val captured = profiles.captureEdit(profile, adding)
        Editor(captured, checkNotNull(accounts.accountFor(captured.runtime)))
    }.getOrElse { mutable.value = mutable.value.copy(message = "The profile changed. Reopen its editor."); null }
    fun captureSelection(profile: UserProfile): Editor? = runCatching {
        val captured = profiles.captureSelection(profile)
        Editor(captured, checkNotNull(accounts.accountFor(captured.runtime)))
    }.getOrElse { mutable.value = mutable.value.copy(message = "The profile changed. Unlock the current profile again."); null }
    fun commitEditor(editor: Editor, action: () -> Unit): Boolean = runCatching {
        profiles.withEditTarget(editor.target) {
            check(accounts.withProfileMutation(editor.target.runtime, editor.account) { action(); true }) { "Account changed" }
        }; refresh(); true
    }.getOrElse { mutable.value = mutable.value.copy(message = "The profile changed. Reopen its editor before saving."); false }
    fun close() {
        request?.cancel(); request = null; target = null
        mutable.value = mutable.value.copy(formProfile = null, busy = false, message = null)
        refresh()
    }
    fun submit(email: String, password: String) {
        val captured = target ?: return
        if (mutable.value.busy || email.isBlank() || password.isEmpty()) return
        mutable.value = mutable.value.copy(busy = true, message = null)
        request = viewModelScope.launch {
            try {
                val mounted = withContext(Dispatchers.IO) { accounts.signInStreaming(captured, email.trim(), password) }
                if (target === captured) {
                    target = null
                    mutable.value = mutable.value.copy(formProfile = null, busy = false,
                        message = if (mounted) "This profile's verified streaming account is ready. Any historical data needing attribution remains pending."
                            else "Account verified. Complete the remaining profile sign-ins to open the native account.")
                    refresh()
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                if (target === captured) mutable.value = mutable.value.copy(busy = false,
                    message = "Sign-in could not be confirmed. Reopen the account and check its connection before trying again; no unverified result is being shown.")
            }
        }
    }
    class Factory(private val accounts: NativeAccountCoordinator) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass == NativeStreamingAccountViewModel::class.java)
            @Suppress("UNCHECKED_CAST") return NativeStreamingAccountViewModel(accounts) as T
        }
    }
}
