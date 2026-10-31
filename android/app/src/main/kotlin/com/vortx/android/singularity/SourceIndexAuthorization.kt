package com.vortx.android.singularity

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

/** Process-local authorization boundary. No account, configured URL, credential, or token is retained here. */
internal object SourceIndexLifecycle {
    private val lock = Any()
    private var epoch = 0L
    private var nextID = 0L
    private val observers = mutableMapOf<Long, Pair<Long, () -> Unit>>()
    private val processIOScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    internal fun currentEpoch(): Long = synchronized(lock) { epoch }
    internal fun dispatchTeardown(action: () -> Unit) {
        processIOScope.launch(Dispatchers.IO) { runCatching(action) }
    }

    /** Every relevant write boundary calls this before publishing its replacement facts. */
    fun invalidate() {
        val callbacks = retireEpoch()
        // Native/auth predicates and cancellation must never execute under this lock.
        callbacks.forEach { runCatching { it() } }
    }

    /** Native/auth callers may still hold their own locks. Fence now; run disconnect/UI callbacks off-thread. */
    fun invalidateDeferred() {
        val callbacks = retireEpoch()
        dispatchTeardown { callbacks.forEach { runCatching { it() } } }
    }

    private fun retireEpoch(): List<() -> Unit> = synchronized(lock) {
            epoch += 1
            observers.values.map { it.second }.also { observers.clear() }
    }

    internal fun onEpochInvalidated(expected: Long, callback: () -> Unit): AutoCloseable {
        val id = synchronized(lock) {
            if (epoch != expected) null else (++nextID).also { observers[it] = expected to callback }
        }
        if (id == null) runCatching(callback)
        return AutoCloseable { if (id != null) synchronized(lock) { observers.remove(id) } }
    }

    fun issue(isCurrent: () -> Boolean, moatProvider: suspend () -> String?): SourceIndexAuthorization? {
        val original = currentEpoch()
        val lease = SourceIndexAuthorization.create(original, isCurrent, moatProvider)
        lease.attach(onEpochInvalidated(original, lease::close))
        if (lease.isCurrent()) return lease
        lease.close()
        return null
    }
}

/** Opaque capability issued only after the App joins its original native, account, vault and gate facts. */
internal class SourceIndexAuthorization private constructor(
    private val epoch: Long,
    private val predicate: () -> Boolean,
    private val moatProvider: suspend () -> String?,
) : AutoCloseable {
    private val lock = Any()
    private val closed = AtomicBoolean(false)
    private var nextID = 0L
    private val callbacks = mutableMapOf<Long, () -> Unit>()
    private var epochRegistration: AutoCloseable? = null

    companion object {
        internal fun create(epoch: Long, predicate: () -> Boolean, moat: suspend () -> String?) =
            SourceIndexAuthorization(epoch, predicate, moat)
    }

    internal fun attach(registration: AutoCloseable) {
        val keep = synchronized(lock) {
            if (closed.get()) false else { epochRegistration = registration; true }
        }
        if (!keep) registration.close()
    }

    fun isCurrent(): Boolean {
        if (isRetired()) return false
        // The typed native/account admission may acquire its own locks. Invoke it without our locks.
        val permitted = runCatching(predicate).getOrDefault(false)
        if (!permitted) {
            closeDeferred()
            return false
        }
        return !isRetired()
    }

    /** Scalar witness for callers already holding repository/native locks. Never calls the live predicate. */
    fun isRetired(): Boolean = closed.get() || SourceIndexLifecycle.currentEpoch() != epoch

    fun onRevoked(callback: () -> Unit): AutoCloseable {
        val id = synchronized(lock) {
            if (closed.get()) null else (++nextID).also { callbacks[it] = callback }
        }
        if (id == null) SourceIndexLifecycle.dispatchTeardown(callback)
        else if (!isCurrent()) closeDeferred()
        return AutoCloseable { if (id != null) synchronized(lock) { callbacks.remove(id) } }
    }

    internal suspend fun moatToken(): String? {
        currentCoroutineContext().ensureActive()
        if (!isCurrent()) return null
        val token = moatProvider()?.takeIf(String::isNotBlank)
        currentCoroutineContext().ensureActive()
        return token?.takeIf { isCurrent() }
    }

    override fun close() {
        val retired = retire() ?: return
        retired.first?.close()
        retired.second.forEach { runCatching { it() } }
    }

    /** For owners retiring under Session/repository locks: synchronous rejection, off-thread cancellation. */
    fun closeDeferred() {
        val retired = retire() ?: return
        retired.first?.close()
        SourceIndexLifecycle.dispatchTeardown { retired.second.forEach { runCatching { it() } } }
    }

    private fun retire(): Pair<AutoCloseable?, List<() -> Unit>>? = synchronized(lock) {
            if (!closed.compareAndSet(false, true)) return@synchronized null
            val registration = epochRegistration
            epochRegistration = null
            val actions = callbacks.values.toList()
            callbacks.clear()
            registration to actions
    }
}
