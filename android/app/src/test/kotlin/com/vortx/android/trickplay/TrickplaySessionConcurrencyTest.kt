package com.vortx.android.trickplay

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class TrickplaySessionConcurrencyTest {

    @Test
    fun `teardown waits for issued frame admission and closes the queue`() = runBlocking {
        val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val queue = TrickplayAdmissionQueue(workerScope)
            val admissionStarted = CompletableDeferred<Unit>()
            val releaseAdmission = CompletableDeferred<Unit>()
            val retainedRevisions = mutableListOf<Long>()
            var finalSnapshot = emptyList<Long>()

            assertNotNull(
                queue.enqueue {
                    admissionStarted.complete(Unit)
                    releaseAdmission.await()
                    retainedRevisions += 1L
                },
            )
            withTimeout(2_000L) { admissionStarted.await() }

            val teardown = queue.closeAndEnqueue { finalSnapshot = retainedRevisions.toList() }

            assertNotNull(teardown)
            assertFalse(requireNotNull(teardown).isCompleted)
            assertNull(queue.enqueue { retainedRevisions += 2L })
            assertNull(queue.closeAndEnqueue { finalSnapshot = listOf(2L) })

            releaseAdmission.complete(Unit)
            withTimeout(2_000L) { teardown.join() }

            assertEquals(listOf(1L), finalSnapshot)
            assertEquals(listOf(1L), retainedRevisions)
        } finally {
            workerScope.cancel()
        }
    }

    @Test
    fun `cancellation still completes the latch and launches deferred work as a fresh job`() = runBlocking {
        val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val uploadStarted = CompletableDeferred<Unit>()
            val completionStarted = CompletableDeferred<Unit>()
            val completionGate = Mutex(locked = true)
            val drained = CompletableDeferred<String>()
            val activeUpload = workerScope.launch {
                try {
                    uploadStarted.complete(Unit)
                    awaitCancellation()
                } finally {
                    completeAndLaunchNextUpload(
                        complete = {
                            completionStarted.complete(Unit)
                            completionGate.withLock { "final-snapshot" }
                        },
                        launchNext = { next -> workerScope.launch { drained.complete(next) } },
                    )
                }
            }

            withTimeout(2_000L) { uploadStarted.await() }
            activeUpload.cancel()
            withTimeout(2_000L) { completionStarted.await() }
            assertFalse(activeUpload.isCompleted)

            completionGate.unlock()
            withTimeout(2_000L) { activeUpload.join() }

            assertEquals("final-snapshot", withTimeout(2_000L) { drained.await() })
        } finally {
            workerScope.cancel()
        }
    }
}
