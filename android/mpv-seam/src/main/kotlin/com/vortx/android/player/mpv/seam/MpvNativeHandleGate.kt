package com.vortx.android.player.mpv.seam

/**
 * Lifetime gate for one native mpv pointer.
 *
 * A volatile/non-zero pointer check cannot protect a JNI call from a concurrent destroy: the pointer
 * can be freed after the check and before native code dereferences it. This gate leases the handle to
 * each call, prevents new leases once destruction starts, and destroys exactly once. Destruction never
 * blocks the request thread on an existing lease. Instead, the last lease releaser performs finalization
 * after leaving native code. This lets an event-listener destroy return so the event loop can unwind.
 */
internal class MpvNativeHandleGate(initialHandle: Long) {
    private enum class Phase { ACTIVE, DESTROYING, DESTROYED }

    private val lock = Any()
    private var phase = Phase.ACTIVE
    private var handle = initialHandle
    private var inFlightCalls = 0
    private var originalOwnerLiveness: java.util.concurrent.atomic.AtomicBoolean? = null
    private var destroyAfterLastCall: ((Long) -> Unit)? = null
    private val asyncLeases = mutableSetOf<AsyncLease>()

    init {
        require(initialHandle != 0L) { "native handle must be non-zero" }
    }

    /** Initialization may precede binding, but owner binding is permanent and never renewable. */
    fun bindOriginalOwner(liveness: java.util.concurrent.atomic.AtomicBoolean): Boolean = synchronized(lock) {
        if (phase != Phase.ACTIVE || originalOwnerLiveness != null) return@synchronized false
        originalOwnerLiveness = liveness
        liveness.get()
    }

    fun <T> withHandle(defaultValue: T, call: (Long) -> T): T {
        val leasedHandle = synchronized(lock) {
            if (phase != Phase.ACTIVE || originalOwnerLiveness?.get() == false) return defaultValue
            inFlightCalls += 1
            handle
        }

        return try {
            call(leasedHandle)
        } finally {
            releaseCall()
        }
    }

    /**
     * Pins this original handle for an effect, including its real asynchronous terminal replies and
     * exact grant cleanup. Closing ordinary admission must not strand an already admitted effect.
     * Only the reference transport receives this token; it must not expose an arbitrary cleanup call.
     */
    fun acquireAsyncLease(onDestroy: () -> Unit): AsyncLease? = synchronized(lock) {
        if (phase != Phase.ACTIVE || originalOwnerLiveness?.get() != true) return@synchronized null
        AsyncLease(onDestroy).also {
            inFlightCalls += 1
            asyncLeases.add(it)
        }
    }

    internal inner class AsyncLease internal constructor(internal val onDestroy: () -> Unit) {
        private var closed = false // under the enclosing gate lock

        val isOwnerCurrent: Boolean get() = synchronized(lock) {
            !closed && this in asyncLeases && phase == Phase.ACTIVE && originalOwnerLiveness?.get() == true
        }

        fun <T> submit(defaultValue: T, call: (Long) -> T): T = use(defaultValue, false, call)

        /** Exact abort/revoke only. This does not reopen ordinary handle admission. */
        fun <T> cleanup(defaultValue: T, call: (Long) -> T): T = use(defaultValue, true, call)

        private fun <T> use(defaultValue: T, cleanup: Boolean, call: (Long) -> T): T {
            val leasedHandle = synchronized(lock) {
                if (closed || this !in asyncLeases || handle == 0L || phase == Phase.DESTROYED ||
                    (!cleanup && (phase != Phase.ACTIVE || originalOwnerLiveness?.get() != true))) {
                    return defaultValue
                }
                inFlightCalls += 1 // protects a reply-before-enqueue-return or cleanup/close race
                handle
            }
            return try { call(leasedHandle) } finally { releaseCall() }
        }

        fun close() {
            synchronized(lock) {
                if (closed) return
                closed = true
                check(asyncLeases.remove(this))
            }
            releaseCall()
        }
    }

    private fun releaseCall() {
        val deferredDestroy = synchronized(lock) {
            check(inFlightCalls > 0)
            inFlightCalls -= 1
            if (inFlightCalls != 0) null else destroyAfterLastCall?.let { destroyHandle ->
                destroyAfterLastCall = null
                DestroyWork(handle.also { handle = 0L }, destroyHandle)
            }
        }
        deferredDestroy?.run()
    }

    /**
     * Close handle admission immediately and request exactly-once destruction without blocking.
     * When no call is leased, the returned action owns finalization. With an active call, null is
     * returned and its last releaser executes finalization.
     */
    fun requestDestroy(destroyHandle: (Long) -> Unit): (() -> Unit)? {
        val work = synchronized(lock) {
            if (phase != Phase.ACTIVE) return null
            phase = Phase.DESTROYING
            val immediate = if (inFlightCalls == 0) {
                DestroyWork(handle.also { handle = 0L }, destroyHandle)
            } else {
                destroyAfterLastCall = destroyHandle
                null
            }
            asyncLeases.map { it.onDestroy } to immediate
        }
        // Cancellation may synchronously reenter or complete an effect. No gate monitor crosses it.
        for (cancel in work.first) runCatching(cancel)
        return work.second?.let { destroy -> { destroy.run() } }
    }

    private inner class DestroyWork(
        private val handleToDestroy: Long,
        private val destroyHandle: (Long) -> Unit,
    ) {
        fun run() {
            try {
                destroyHandle(handleToDestroy)
            } finally {
                synchronized(lock) {
                    phase = Phase.DESTROYED
                }
            }
        }
    }
}

/**
 * Serializes a native call while keeping the handle lease outermost. If this is the final lease,
 * deferred destruction runs only after [monitor] has been released.
 */
internal fun <T> MpvNativeHandleGate.withSerializedHandle(
    monitor: Any,
    defaultValue: T,
    call: (Long) -> T,
): T = withHandle(defaultValue) { leasedHandle ->
    synchronized(monitor) {
        call(leasedHandle)
    }
}
