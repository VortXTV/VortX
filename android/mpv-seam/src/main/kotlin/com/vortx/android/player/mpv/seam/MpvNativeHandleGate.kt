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

    private val lock = java.lang.Object()
    private var phase = Phase.ACTIVE
    private var handle = initialHandle
    private var inFlightCalls = 0
    private var destroyAfterLastCall: ((Long) -> Unit)? = null

    init {
        require(initialHandle != 0L) { "native handle must be non-zero" }
    }

    fun <T> withHandle(defaultValue: T, call: (Long) -> T): T {
        val leasedHandle = synchronized(lock) {
            if (phase != Phase.ACTIVE) return defaultValue
            inFlightCalls += 1
            handle
        }

        return try {
            call(leasedHandle)
        } finally {
            val deferredDestroy = synchronized(lock) {
                inFlightCalls -= 1
                if (inFlightCalls != 0) {
                    null
                } else {
                    destroyAfterLastCall?.let { destroyHandle ->
                        destroyAfterLastCall = null
                        DestroyWork(handle.also { handle = 0L }, destroyHandle)
                    }
                }
            }
            deferredDestroy?.run()
        }
    }

    /**
     * Close handle admission immediately and request exactly-once destruction without blocking.
     * When no call is leased, the returned action owns finalization. With an active call, null is
     * returned and its last releaser executes finalization.
     */
    fun requestDestroy(destroyHandle: (Long) -> Unit): (() -> Unit)? {
        val immediateDestroy = synchronized(lock) {
            if (phase != Phase.ACTIVE) return null
            phase = Phase.DESTROYING
            if (inFlightCalls == 0) {
                DestroyWork(handle.also { handle = 0L }, destroyHandle)
            } else {
                destroyAfterLastCall = destroyHandle
                null
            }
        }
        return immediateDestroy?.let { work -> { work.run() } }
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
