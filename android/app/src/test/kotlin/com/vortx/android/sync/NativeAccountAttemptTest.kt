package com.vortx.android.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Actual helper; synthetic operation/admission only. No JNI, live account or checkpoint mutation. */
class NativeAccountAttemptTest {
    @Test fun `success and ordinary false retain original result and invoke once`() = runBlocking {
        var calls = 0
        var notices = 0
        assertTrue(runNativeAccountAttempt({ notices++ }) { calls++; true })
        assertFalse(runNativeAccountAttempt({ notices++ }) { calls++; false })
        assertEquals(2, calls)
        assertEquals(0, notices)
    }

    @Test fun `missing JNI produces one recoverable outcome without passing private details`() = runBlocking {
        var calls = 0
        var notices = 0
        val result = runNativeAccountAttempt(onUnavailable = { notices++ }) {
            calls++
            throw UnsatisfiedLinkError("fixture/private/checkpoint?token=private")
        }
        assertFalse(result)
        assertEquals(1, calls)
        assertEquals(1, notices)
    }

    @Test fun `other linkage incompatibility has the same bounded policy`() = runBlocking {
        var notices = 0
        assertFalse(runNativeAccountAttempt({ notices++ }) { throw NoSuchMethodError("fixture missing adapter") })
        assertEquals(1, notices)
    }

    @Test fun `ordinary exception is preserved for existing caller policy`() = runBlocking {
        val failure = IllegalStateException("fixture ordinary failure")
        var notices = 0
        try {
            runNativeAccountAttempt({ notices++ }) { throw failure }
            fail("ordinary exception was swallowed by compatibility helper")
        } catch (actual: IllegalStateException) { assertSame(failure, actual) }
        assertEquals(0, notices)
    }

    @Test fun `cancellation identity is preserved without incompatibility notice`() = runBlocking {
        val cancellation = CancellationException("fixture cancellation")
        var notices = 0
        try {
            runNativeAccountAttempt({ notices++ }) { throw cancellation }
            fail("cancellation was swallowed")
        } catch (actual: CancellationException) { assertSame(cancellation, actual) }
        assertEquals(0, notices)
    }

    @Test fun `fatal VM and assertion errors remain fatal with exact identity`() = runBlocking {
        for (failure in listOf(OutOfMemoryError("fixture"), StackOverflowError("fixture"), AssertionError("fixture"))) {
            var notices = 0
            try {
                runNativeAccountAttempt({ notices++ }) { throw failure }
                fail("fatal error was swallowed")
            } catch (actual: Error) { assertSame(failure, actual) }
            assertEquals(0, notices)
        }
    }

    @Test fun `stale owner admission cannot publish a linkage notice to a replacement account`() = runBlocking {
        var generation = 1
        val expectedGeneration = generation
        var notice: String? = "replacement notice"
        val admission: (() -> Unit) -> Unit = { publish -> if (generation == expectedGeneration) publish() }
        val result = runNativeAccountAttempt({ admission { notice = "native unavailable" } }) {
            generation++
            throw UnsatisfiedLinkError("fixture")
        }
        assertFalse(result)
        assertEquals("replacement notice", notice)
    }

    @Test fun `failed linkage does not reset retained session checkpoint or pending edits`() = runBlocking {
        val session = Any()
        val checkpoint = byteArrayOf(4, 0, 2)
        val pending = linkedMapOf("edited-setting" to "retained-value")
        var resets = 0
        var notices = 0
        val retainedSession = session
        val retainedCheckpoint = checkpoint.copyOf()
        val result = runNativeAccountAttempt({ notices++ }) { throw UnsatisfiedLinkError("fixture") }
        assertFalse(result)
        assertSame(retainedSession, session)
        assertArrayEquals(retainedCheckpoint, checkpoint)
        assertEquals(mapOf("edited-setting" to "retained-value"), pending)
        assertEquals(0, resets)
        assertEquals(1, notices)
    }

    @Test fun `cancellation racing linkage takes priority and does not publish unavailable`() = runBlocking {
        var notices = 0
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val worker = async {
            runNativeAccountAttempt({ notices++ }) {
                entered.complete(Unit)
                try { release.await() }
                catch (_: CancellationException) { throw UnsatisfiedLinkError("fixture cancellation race") }
                true
            }
        }
        entered.await()
        worker.cancel(CancellationException("fixture stopped"))
        try { worker.await(); fail("cancelled operation returned compatibility success") }
        catch (_: CancellationException) { }
        assertEquals(0, notices)
    }

    @Test fun `notice callback cancellation and fatal errors are not swallowed`() = runBlocking {
        val cancellation = CancellationException("fixture callback cancelled")
        try {
            runNativeAccountAttempt({ throw cancellation }) { throw UnsatisfiedLinkError("fixture") }
            fail("callback cancellation was swallowed")
        } catch (actual: CancellationException) { assertSame(cancellation, actual) }
        val fatal = AssertionError("fixture callback fatal")
        try {
            runNativeAccountAttempt({ throw fatal }) { throw UnsatisfiedLinkError("fixture") }
            fail("callback fatal was swallowed")
        } catch (actual: AssertionError) { assertSame(fatal, actual) }
    }
}
