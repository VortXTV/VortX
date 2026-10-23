package com.vortx.android.engine

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Synthetic disposal closures; no JNI, checkpoint mutation, device or account operation. */
class NativeRetirementDispatchTest {
    @Test fun `successful close alone releases its reservation`() {
        val exact = Any()
        val retained = mutableListOf(exact)
        var closes = 0
        var notices = 0
        runNativeRetirementAttempt(close = {
            closes++
            retained.remove(exact)
        }, onUnconfirmed = { notices++ })
        assertEquals(1, closes)
        assertTrue(retained.isEmpty())
        assertEquals(0, notices)
    }

    @Test fun `ordinary failed close keeps the exact reservation and reports once`() {
        val exact = Any()
        val retained = mutableListOf(exact)
        var notices = 0
        val failingClose: () -> Unit = { throw IllegalStateException("fixture-private-checkpoint-path-and-token") }
        runNativeRetirementAttempt(close = {
            failingClose()
            retained.remove(exact)
        }, onUnconfirmed = { notices++ })
        assertSame(exact, retained.single())
        assertEquals(1, notices)
    }

    @Test fun `cancellation is rethrown without reporting success or failure`() {
        val cancellation = CancellationException("fixture cancellation")
        var notices = 0
        try {
            runNativeRetirementAttempt(close = { throw cancellation }, onUnconfirmed = { notices++ })
            error("Cancellation was swallowed")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
        assertEquals(0, notices)
    }

    @Test fun `fatal error identity is preserved`() {
        val fatal = AssertionError("fixture fatal")
        var notices = 0
        try {
            runNativeRetirementAttempt(close = { throw fatal }, onUnconfirmed = { notices++ })
            error("Fatal error was swallowed")
        } catch (actual: AssertionError) {
            assertSame(fatal, actual)
        }
        assertEquals(0, notices)
    }

    @Test fun `failed attempt is not automatically retried or acknowledged`() {
        var closes = 0
        var acknowledged = false
        var notices = 0
        val failingClose: () -> Unit = { throw IllegalStateException("fixture unconfirmed retirement") }
        runNativeRetirementAttempt(close = {
            closes++
            failingClose()
            acknowledged = true
        }, onUnconfirmed = { notices++ })
        assertEquals(1, closes)
        assertFalse(acknowledged)
        assertEquals(1, notices)
    }

    @Test fun `ordinary disposal failure does not escape the supervisor child`() = runBlocking {
        val escaped = CompletableDeferred<Throwable>()
        val supervisor = SupervisorJob()
        val scope = CoroutineScope(supervisor + Dispatchers.Unconfined + CoroutineExceptionHandler { _, error ->
            escaped.complete(error)
        })
        var notices = 0
        var siblingRan = false
        try {
            scope.launch {
                runNativeRetirementAttempt(close = { throw IllegalStateException("fixture retirement") },
                    onUnconfirmed = { notices++ })
            }.join()
            scope.launch { siblingRan = true }.join()
            assertEquals(1, notices)
            assertFalse(escaped.isCompleted)
            assertTrue(supervisor.isActive)
            assertTrue(siblingRan)
        } finally {
            supervisor.cancel()
        }
    }
}
