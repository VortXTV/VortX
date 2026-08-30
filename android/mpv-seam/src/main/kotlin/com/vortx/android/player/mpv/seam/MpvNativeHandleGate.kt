package com.vortx.android.player.mpv.seam

/**
 * Lifetime gate for one native mpv pointer.
 *
 * A volatile/non-zero pointer check cannot protect a JNI call from a concurrent destroy: the pointer
 * can be freed after the check and before native code dereferences it. This gate leases the handle to
 * each call, prevents new leases once destruction starts, waits for existing leases to finish, then
 * destroys exactly once. The destroy callback runs without the monitor held because native teardown
 * joins mpv's event thread, whose final Java callbacks must be able to fail closed instead of deadlock.
 */
internal class MpvNativeHandleGate(initialHandle: Long) {
    private enum class Phase { ACTIVE, DESTROYING, DESTROYED }

    private val lock = java.lang.Object()
    private var phase = Phase.ACTIVE
    private var handle = initialHandle
    private var inFlightCalls = 0

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
            synchronized(lock) {
                inFlightCalls -= 1
                if (inFlightCalls == 0) lock.notifyAll()
            }
        }
    }

    fun destroy(destroyHandle: (Long) -> Unit) {
        var interrupted = false
        val handleToDestroy = synchronized(lock) {
            while (phase == Phase.DESTROYING) {
                try {
                    lock.wait()
                } catch (_: InterruptedException) {
                    interrupted = true
                }
            }
            if (phase == Phase.DESTROYED) {
                if (interrupted) Thread.currentThread().interrupt()
                return
            }

            phase = Phase.DESTROYING
            while (inFlightCalls != 0) {
                try {
                    lock.wait()
                } catch (_: InterruptedException) {
                    interrupted = true
                }
            }
            handle.also { handle = 0L }
        }

        try {
            destroyHandle(handleToDestroy)
        } finally {
            synchronized(lock) {
                phase = Phase.DESTROYED
                lock.notifyAll()
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
    }
}
