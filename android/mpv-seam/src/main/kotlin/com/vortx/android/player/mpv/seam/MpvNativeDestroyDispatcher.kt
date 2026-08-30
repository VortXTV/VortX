package com.vortx.android.player.mpv.seam

/**
 * Keeps native destruction off mpv's JNI callback stack.
 *
 * Native CallVoidMethod invokes listeners synchronously on mpv's event thread. A listener is allowed to
 * call the public destroy method, but joining or freeing that native event thread from inside its own
 * callback is unsafe. Callback depth and one pending action are thread-local. The action runs in the
 * outer callback's finally block, after every Java listener has returned but before control goes back to
 * native CallVoidMethod. Native teardown then requests loop exit without joining itself and finalizes
 * only after the Java method and native local-ref handling fully unwind.
 */
internal class MpvNativeDestroyDispatcher {
    private val callbackDepth = ThreadLocal<Int>()
    private val pendingDestroy = ThreadLocal<() -> Unit>()

    fun <T> withinNativeCallback(callback: () -> T): T {
        val previousDepth = callbackDepth.get() ?: 0
        callbackDepth.set(previousDepth + 1)
        return try {
            callback()
        } finally {
            if (previousDepth == 0) {
                val destroy = pendingDestroy.get()
                pendingDestroy.remove()
                callbackDepth.remove()
                destroy?.invoke()
            } else {
                callbackDepth.set(previousDepth)
            }
        }
    }

    fun dispatchDestroy(destroy: () -> Unit) {
        if ((callbackDepth.get() ?: 0) == 0) {
            destroy()
            return
        }

        check(pendingDestroy.get() == null) { "native destroy already pending for this callback" }
        pendingDestroy.set(destroy)
    }
}
