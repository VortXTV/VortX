package com.vortx.android.player

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/** Owns construction before a decoder exists, then transfers only a fully prepared live decoder. */
internal class PlayerEngineBuildOwner(
    private val onBound: () -> Unit,
    private val onReleased: () -> Unit,
    private val beforeRelease: (PlayerEngine) -> Unit = {},
) : AutoCloseable {
    private val lock = Any()
    private var begun = false
    private var retired = false
    private var engine: PlayerEngine? = null

    suspend fun build(
        createBackground: (() -> PlayerEngine?)?,
        createForeground: () -> PlayerEngine,
        prepare: (PlayerEngine) -> Unit,
        backgroundDispatcher: CoroutineDispatcher = Dispatchers.Default,
    ): PlayerEngine? {
        val caller = currentCoroutineContext()[Job]
        currentCoroutineContext().ensureActive()
        synchronized(lock) {
            if (retired) return null
            check(!begun) { "Player construction already started" }
            begun = true
            // Count the pending constructor too: disposal cannot acknowledge decoder release early.
            onBound()
        }
        var candidate: PlayerEngine? = null
        var transferred = false
        fun current() = caller?.isActive != false && synchronized(lock) { !retired }
        try {
            if (createBackground != null) {
                withContext(backgroundDispatcher + NonCancellable) {
                    // Record locally before any preparation or dispatcher-return cancellation point.
                    candidate = createBackground()
                    candidate?.let { if (current()) prepare(it) }
                }
            }
            currentCoroutineContext().ensureActive()
            if (!current()) return null
            if (candidate == null) {
                candidate = createForeground()
                if (current()) prepare(requireNotNull(candidate))
            }
            currentCoroutineContext().ensureActive()
            return synchronized(lock) {
                if (retired || caller?.isActive == false) null else candidate.also { engine = it; transferred = true }
            }
        } finally {
            // Runs even when withContext throws on its prompt-cancellation return to the caller.
            if (!transferred) release(candidate)
        }
    }

    override fun close() {
        val owned = synchronized(lock) {
            retired = true
            engine.also { engine = null }
        }
        // An in-progress constructor owns its local candidate until its finally; never block UI disposal
        // on a native call or release a handle while preparation is still using it.
        if (owned != null) release(owned)
    }

    fun get(): PlayerEngine? = synchronized(lock) { engine }

    private fun release(owned: PlayerEngine?) {
        if (owned != null) {
            beforeRelease(owned)
            owned.release()
        }
        // If release throws, retain the decoder gate rather than falsely certify resource reclamation.
        onReleased()
    }
}

/** Registered before the Connecting return, not conditional on decoder publication. */
internal class PlayerPlaybackLeaseOwner(
    private val lease: AutoCloseable?,
    onBound: () -> Unit,
    private val onReleased: () -> Unit,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    init { if (lease != null) onBound() }
    override fun close() {
        if (!closed.compareAndSet(false, true) || lease == null) return
        lease.close()
        onReleased()
    }
}
