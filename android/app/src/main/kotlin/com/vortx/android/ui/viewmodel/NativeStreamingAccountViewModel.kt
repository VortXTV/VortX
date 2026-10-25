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
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.util.concurrent.atomic.AtomicReference
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
    private val profiles = NativeProfileAccess(
        publicationAdmission = { runtime, action ->
            val account = accounts.accountFor(runtime)
            account != null && accounts.withProfileMutation(runtime, account, action)
        },
        session = { accounts.session() },
    )
    data class State(val loading: Boolean = true, val mounted: Boolean = false, val profiles: List<UserProfile> = emptyList(), val activeID: String? = null,
                     val streaming: List<NativeAccountCoordinator.StreamingProfile> = emptyList(),
                     val migration: NativeAccountCoordinator.MigrationStatus? = null,
                     val formProfile: UserProfile? = null, val busy: Boolean = false, val message: String? = null)
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private var target: NativeAccountCoordinator.StreamingTarget? = null
    private var request: Job? = null
    private var retryTarget: NativeAccountCoordinator.MigrationTarget? = null

    // At most one full native snapshot is being read and one newest request is pending. A fresh
    // identity closes A -> B -> A completion reuse without a wrapping numeric generation.
    private val refreshRequests = Channel<Unit>(Channel.CONFLATED)
    private val refreshGeneration = AtomicReference(Any())
    private var rejectedRefresh: Any? = null
    private var presentationIdentity: Any? = Any()

    init {
        viewModelScope.launch {
            while (refreshRequests.receiveCatching().isSuccess) {
                val generation = refreshGeneration.get()
                try {
                    val snapshot = withContext(Dispatchers.Default) { accounts.captureStreamingPresentation() }
                    currentCoroutineContext().ensureActive()
                    if (refreshGeneration.get() !== generation) continue
                    val published = snapshot.publishIfCurrent {
                        if (refreshGeneration.get() === generation) {
                            // UI actions may have changed the form while the snapshot was reading.
                            // Copy the current state so their busy/form/message fields remain intact.
                            val projection = snapshot.projection
                            mutable.value = mutable.value.copy(loading = false, mounted = projection != null,
                                profiles = projection?.profiles ?: snapshot.streaming.map { it.profile },
                                activeID = projection?.activeID, streaming = snapshot.streaming, migration = snapshot.migration)
                        }
                    }
                    if (!published && refreshGeneration.get() === generation) {
                        // One bounded retry closes a stamp race even if its flow wake was conflated.
                        // Permanent admission failure must not spin or strand initial loading forever.
                        if (rejectedRefresh !== generation) {
                            rejectedRefresh = generation
                            refreshRequests.trySend(Unit)
                        } else refreshFailed(generation)
                    }
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (_: LinkageError) {
                    refreshFailed(generation)
                } catch (_: Exception) {
                    refreshFailed(generation)
                }
            }
        }
        viewModelScope.launch {
            accounts.changes.collectLatest {
                val identity = accounts.streamingPresentationIdentity()
                if (identity !== presentationIdentity) {
                    presentationIdentity = identity
                    // A new/retired account mount or replaced setup cannot keep the former roster,
                    // PIN/form target or error visible while its new background snapshot is pending.
                    // Mount/setup transitions can be produced by the currently admitted mutation
                    // itself. Keep its job handle for close()/ViewModel disposal; its captured native
                    // fences decide commit, while these retired UI targets reject its late message.
                    target = null; retryTarget = null
                    mutable.value = State()
                }
                refresh()
                runCatching { accounts.session() }.getOrNull()?.updates?.collect { refresh() }
            }
        }
    }

    /** Enqueue only; neither the UI nor a native mutation's callback waits for state serialization. */
    fun refresh() {
        refreshGeneration.set(Any())
        refreshRequests.trySend(Unit)
    }

    private fun refreshFailed(generation: Any) {
        if (refreshGeneration.get() !== generation) return
        mutable.value = mutable.value.copy(loading = false, mounted = false, profiles = emptyList(), activeID = null,
            streaming = emptyList(), migration = null,
            message = mutable.value.message ?: "Profiles couldn't load. Try again or export diagnostics.")
    }

    override fun onCleared() {
        refreshRequests.close()
        super.onCleared()
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
        request?.cancel(); request = null; target = null; retryTarget = null
        mutable.value = mutable.value.copy(formProfile = null, busy = false, message = null)
        refresh()
    }
    fun retryMigration() {
        if (mutable.value.busy) return
        val captured = runCatching { accounts.captureMigrationTarget() }.getOrElse {
            mutable.value = mutable.value.copy(message = "The account changed. Reopen migration setup."); return
        }
        retryTarget = captured
        mutable.value = mutable.value.copy(busy = true, message = null)
        request = viewModelScope.launch {
            try {
                val complete = withContext(Dispatchers.IO) { accounts.retryMigration(captured) }
                if (retryTarget === captured) {
                    retryTarget = null
                    mutable.value = mutable.value.copy(busy = false, message = if (complete) "Preserved account data is ready."
                        else "Original data is preserved. Episode inventories, profile sign-ins, or Watchlist attribution still need attention.")
                    refresh()
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                if (retryTarget === captured) {
                    retryTarget = null
                    mutable.value = mutable.value.copy(busy = false, message = "Migration could not be confirmed. Original history is preserved; reopen setup before retrying.")
                    refresh()
                }
            }
        }
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
                            else "Account verified. Original history is preserved while episode inventories or remaining profile sign-ins are pending.")
                    refresh()
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                if (target === captured) mutable.value = mutable.value.copy(busy = false,
                    message = "Sign-in could not be confirmed. Reopen the account and check its connection before trying again; no unverified result is being shown.")
            }
        }
    }
    class Creator(private val accounts: NativeAccountCoordinator) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass == NativeStreamingAccountViewModel::class.java)
            @Suppress("UNCHECKED_CAST") return NativeStreamingAccountViewModel(accounts) as T
        }
    }
}
