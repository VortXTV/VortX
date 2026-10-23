package com.vortx.android.diagnostics

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticShareOperationTest {
    @Test fun `locked admission never stages or shares`() = runBlocking {
        var staged = false
        var presented = false
        val outcome = performDiagnosticShare(stage = { staged = true; Any() },
            present = { presented = true; true }, mayShare = { false })
        assertEquals(DiagnosticShareOutcome.BLOCKED, outcome)
        assertFalse(staged || presented)
    }

    @Test fun `profile replacement during staging prevents the chooser`() = runBlocking {
        var allowed = true
        var presented = false
        val outcome = performDiagnosticShare(stage = { allowed = false; Any() },
            present = { presented = true; true }, mayShare = { allowed })
        assertEquals(DiagnosticShareOutcome.BLOCKED, outcome)
        assertFalse(presented)
    }

    @Test fun `staged export is shared once without an account or probe dependency`() = runBlocking {
        val staged = Any()
        var presentations = 0
        val result = performDiagnosticShare(stage = { staged }, present = {
            assertSame(staged, it)
            presentations++
            true
        })
        assertEquals(DiagnosticShareOutcome.SHARED, result)
        assertEquals(null, result.message)
        assertEquals(1, presentations)
    }

    @Test fun `staging failure never reaches share presentation or displays exception details`() = runBlocking {
        var presented = false
        val result = performDiagnosticShare<Any>(
            stage = { throw IOException("fixture-private-path-and-token") },
            present = { presented = true; true },
        )
        assertFalse(presented)
        assertEquals(DiagnosticShareOutcome.FAILED, result)
        assertFalse(result.message.orEmpty().contains("fixture-private"))
    }

    @Test fun `missing receiver produces a fixed useful notice`() = runBlocking {
        assertEquals(DiagnosticShareOutcome.NO_RECEIVER,
            performDiagnosticShare(stage = { Any() }, present = { false }))
    }

    @Test fun `provider or presentation failure is recoverable without exposing details`() = runBlocking {
        val result = performDiagnosticShare(stage = { Any() }, present = {
            throw SecurityException("fixture-private-uri")
        })
        assertEquals(DiagnosticShareOutcome.FAILED, result)
        assertFalse(result.message.orEmpty().contains("fixture-private"))
    }

    @Test fun `cancellation is rethrown before presenting`() = runBlocking {
        val cancel = CancellationException("fixture cancellation")
        var presented = false
        try {
            performDiagnosticShare<Any>(stage = { throw cancel }, present = { presented = true; true })
            error("Cancellation was swallowed")
        } catch (actual: CancellationException) { assertSame(cancel, actual) }
        assertFalse(presented)
    }

    @Test fun `fatal errors are not turned into share notices`() = runBlocking {
        val fatal = AssertionError("fixture fatal")
        try {
            performDiagnosticShare<Any>(stage = { throw fatal }, present = { true })
            error("Fatal error was swallowed")
        } catch (actual: AssertionError) { assertSame(fatal, actual) }
        assertTrue(DiagnosticShareOutcome.FAILED.message.orEmpty().isNotBlank())
    }
}
