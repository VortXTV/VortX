package com.vortx.android.trickplay

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Serializes frame admission without putting sheet builds or network uploads on the serial lane.
 * Closing and enqueueing teardown happen under the same monitor as frame registration, so teardown
 * observes every frame call that won the race before close and rejects every frame call after it.
 */
internal class TrickplayAdmissionQueue(private val scope: CoroutineScope) {
    private val monitor = Any()
    private var tail: Job? = null
    private var closed = false

    fun enqueue(block: suspend () -> Unit): Job? = synchronized(monitor) {
        if (closed) null else enqueueLocked(block)
    }

    fun closeAndEnqueue(block: suspend () -> Unit): Job? = synchronized(monitor) {
        if (closed) return@synchronized null
        closed = true
        enqueueLocked(block)
    }

    private fun enqueueLocked(block: suspend () -> Unit): Job {
        val predecessor = tail
        val queued = scope.launch(start = CoroutineStart.LAZY) {
            predecessor?.join()
            block()
        }
        tail = queued
        queued.start()
        return queued
    }
}

/**
 * Clears upload ownership even when the active upload coroutine is cancelled, then hands any deferred
 * upload to a fresh job supplied by the session scope. The completion callback may suspend on its mutex.
 */
internal suspend fun <T> completeAndLaunchNextUpload(
    complete: suspend () -> T?,
    launchNext: (T) -> Unit,
) {
    withContext(NonCancellable) {
        complete()?.let(launchNext)
    }
}
