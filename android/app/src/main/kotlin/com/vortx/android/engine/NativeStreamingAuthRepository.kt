package com.vortx.android.engine

import com.vortx.android.data.AuthManagement
import com.vortx.android.data.AuthRepository
import com.vortx.android.model.AuthState
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Optional owner Stremio credentials only. VortX login, native binding and library are untouched. */
internal class NativeStreamingAuthRepository(private val accounts: NativeAccountCoordinator, scope: CoroutineScope) : AuthRepository {
    private val lock = Any()
    private val refreshSequence = AtomicLong()
    @Volatile private var publicationUncertain = false
    private var target: NativeAccountCoordinator.OwnerAuthTarget? = null
    private val mutableAuth = MutableStateFlow<AuthState>(AuthState.SignedOut)
    private val mutableManagement = MutableStateFlow(AuthManagement(false, "Open your authenticated VortX account first."))
    override val authState = mutableAuth.asStateFlow()
    override val management = mutableManagement.asStateFlow()

    init {
        scope.launch {
            accounts.changes.collectLatest {
                refresh()
                runCatching { accounts.session() }.getOrNull()?.updates?.collect { refresh() }
            }
        }
    }

    internal fun refresh() {
        val sequence = refreshSequence.incrementAndGet()
        val current = runCatching { accounts.ownerAuthTarget() }.getOrNull()
        if (current != null) {
            val published = runCatching { accounts.withOwnerAuthTarget(current) {
                synchronized(lock) {
                    if (sequence != refreshSequence.get()) return@synchronized
                    val revision = if (target?.matches(current) == true) mutableManagement.value.revision else UUID.randomUUID().toString()
                    target = current
                    publicationUncertain = false // Reconciled exact durable intent + token under current admission.
                    mutableAuth.value = current.verifiedUID?.let { AuthState.SignedIn(null, it) } ?: AuthState.SignedOut
                    mutableManagement.value = AuthManagement(current.canManage,
                        if (current.canManage) "Optional connection for Main. Your VortX identity and saved native data stay unchanged."
                        else "Open Main and unlock its PIN to manage the optional Stremio account.", revision)
                }
            } }.isSuccess
            if (published) return
        }
        synchronized(lock) {
            if (sequence != refreshSequence.get()) return@synchronized
            target = null
            mutableAuth.value = AuthState.SignedOut
            mutableManagement.value = AuthManagement(false,
                if (publicationUncertain) "Credential update result is uncertain. Reopen the account to reconcile secure storage; native data is unchanged."
                else "Open your authenticated VortX account first. If secure credentials are unavailable, reconnect from Main.", UUID.randomUUID().toString())
        }
    }

    private fun capture(revision: String?): NativeAccountCoordinator.OwnerAuthTarget = synchronized(lock) {
        check(revision != null && mutableManagement.value.revision == revision && mutableManagement.value.canManage) {
            "Open Main and unlock its PIN before managing this account."
        }
        checkNotNull(target) { "Open the native account first." }
    }

    override suspend fun signIn(email: String, password: String) = signInForRevision(email, password, management.value.revision)
    override suspend fun signInForRevision(email: String, password: String, revision: String?): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val captured = capture(revision)
            require(email.isNotBlank() && password.isNotEmpty())
            accounts.signInOwner(captured, email.trim(), password)
            Result.success(Unit)
        } catch (cancel: CancellationException) { throw cancel }
        catch (uncertain: NativeOwnerPublicationUncertain) { publicationUncertain = true; Result.failure(uncertain) }
        catch (_: Exception) { Result.failure(IllegalStateException("Stremio connection could not be confirmed. Reopen Main and try again; your native data is unchanged.")) }
        finally { refresh() }
    }

    override suspend fun signOut() = signOutForRevision(management.value.revision)
    override suspend fun signOutForRevision(revision: String?) = withContext(Dispatchers.IO) {
        try { accounts.signOutOwner(capture(revision)) }
        catch (cancel: CancellationException) { throw cancel }
        catch (uncertain: NativeOwnerPublicationUncertain) { publicationUncertain = true; throw uncertain }
        catch (_: Exception) { throw IllegalStateException("Stremio disconnection could not be confirmed. Reopen Main; your VortX account remains signed in.") }
        finally { refresh() }
    }
}
