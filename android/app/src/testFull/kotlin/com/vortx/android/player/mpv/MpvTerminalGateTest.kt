package com.vortx.android.player.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Exercises the REAL production terminal wiring ([MpvTerminalGate] -- the lock/gate/publication
/// object MpvPlayer delegates to) with scripted adversarial callback sequences: teardown races,
/// replacement windows, duplicates, every typed reason, and old-generation interleaving. Publication
/// is captured in order so reset-vs-terminal ordering is asserted, not assumed.
class MpvTerminalGateTest {
    private class Published {
        var hasEnded = false
        var hasError = false
        var isBuffering = false
    }

    private fun gate(): Pair<MpvTerminalGate, MutableList<Published>> {
        val publications = mutableListOf<Published>()
        val gate = MpvTerminalGate { hasEnded, hasError, isBuffering ->
            publications += Published().apply {
                this.hasEnded = hasEnded
                this.hasError = hasError
                this.isBuffering = isBuffering
            }
        }
        return gate to publications
    }

    @Test
    fun `first load publishes connecting state`() {
        val (gate, published) = gate()
        gate.beginFirstLoad()

        assertEquals(1, published.size)
        assertFalse(published[0].hasEnded)
        assertFalse(published[0].hasError)
        assertTrue(published[0].isBuffering)
    }

    @Test
    fun `natural eof publishes ended exactly once and duplicates are dropped`() {
        val (gate, published) = gate()
        gate.beginFirstLoad()

        val first = gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))
        val duplicate = gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))

        assertNotNull(first)
        assertNull("duplicate terminal must be a no-op", duplicate)
        assertEquals(2, published.size)
        val verdict = published[1]
        assertTrue(verdict.hasEnded)
        assertFalse(verdict.hasError)
        assertFalse(verdict.isBuffering)
    }

    @Test
    fun `midstream error stays retryable and never ends`() {
        val (gate, published) = gate()
        gate.beginFirstLoad()

        gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -13))

        val verdict = published.last()
        assertFalse(verdict.hasEnded)
        assertTrue(verdict.hasError)
    }

    @Test
    fun `stop quit redirect classify without watched or error`() {
        for (reason in listOf(MpvTerminalReason.STOP, MpvTerminalReason.QUIT, MpvTerminalReason.REDIRECT)) {
            val (gate, published) = gate()
            gate.beginFirstLoad()

            gate.onTerminal(MpvTerminalEvent(reason))

            val verdict = published.last()
            assertFalse("$reason must not mark watched", verdict.hasEnded)
            assertFalse("$reason must not become an error", verdict.hasError)
        }
    }

    @Test
    fun `unknown reason fails safe as retryable error without ending`() {
        val (gate, published) = gate()
        gate.beginFirstLoad()

        val applied = gate.onTerminal(MpvTerminalEvent.fromNative(99, -7))

        assertNotNull(applied)
        assertEquals(MpvTerminalReason.UNKNOWN, applied!!.reason)
        val verdict = published.last()
        assertTrue(verdict.hasError)
        assertFalse(verdict.hasEnded)
    }

    @Test
    fun `old source terminal inside the replacement window is suppressed until new start_file`() {
        val (gate, published) = gate()
        gate.beginFirstLoad()
        // Source A plays; user loads source B while A is still running.
        gate.beginReplacementLoad()
        val before = published.size

        // A's final END_FILE (any reason -- even EOF) lands inside the window: dropped.
        assertNull(gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF)))
        assertNull(gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.STOP)))
        assertEquals("suppressed callbacks must not publish UI", before, published.size)

        // B's START_FILE closes the window; B's real terminals classify normally again.
        gate.onSourceStarted()
        val applied = gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))
        assertNotNull(applied)
        assertTrue(published.last().hasEnded)
    }

    @Test
    fun `adversarial old generation eof cannot classify the next source as watched`() {
        // The t2 finding-B scenario: a stale old-source EOF racing a fresh load. With real payloads
        // there is no global flag left to stale-race, and the window suppression holds regardless of
        // how the stale callback interleaves with the reset publication.
        val (gate, published) = gate()
        gate.beginFirstLoad() // source A begins
        gate.onSourceStarted()
        gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -5)) // A fails midstream

        gate.beginReplacementLoad() // source B load begins; UI reset published under the same lock
        assertEquals(false, published.last().hasError)

        // Stale A-side ERROR arrives after B's reset but before B's START_FILE: suppressed.
        assertNull(gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -5)))
        // Even a stale A-side EOF cannot mark anything watched inside the window.
        assertNull(gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF)))
        assertFalse(published.last().hasEnded)

        gate.onSourceStarted() // B actually starts
        // B then fails: classified as B's own retryable error.
        gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -2))
        val verdict = published.last()
        assertTrue(verdict.hasError)
        assertFalse(verdict.hasEnded)
    }

    @Test
    fun `terminal after release is dropped entirely`() {
        val (gate, published) = gate()
        gate.beginFirstLoad()
        val before = published.size

        gate.release()
        // The teardown race: an already-dispatched native EOF callback fires after release().
        assertNull(gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF)))
        assertEquals("released gate must not publish", before, published.size)
        // And once released, no later callback can resurrect publication.
        assertNull(gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.STOP)))
        assertEquals(before, published.size)
    }

    @Test
    fun `replacement reset and terminal verdict publish under one total order`() {
        // Reset (buffering=true, no flags) always precedes any post-reset verdict in the publication
        // sequence; nothing can interleave between them because both run under the gate lock.
        val (gate, published) = gate()
        gate.beginFirstLoad()
        gate.onSourceStarted()
        gate.beginReplacementLoad()
        gate.onSourceStarted()
        gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))

        assertEquals(3, published.size)
        assertTrue(published[0].isBuffering && !published[0].hasEnded)
        assertTrue(published[1].isBuffering && !published[1].hasEnded)
        assertFalse(published[2].isBuffering)
        assertTrue(published[2].hasEnded)
    }

    @Test
    fun `start_file before any terminal re-arms classification on a consumed source`() {
        // START_FILE arriving when the current source already produced a verdict must not un-consume
        // it (onSourceStarted keeps a consumed source consumed).
        val (gate, published) = gate()
        gate.beginFirstLoad()
        gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.STOP))
        val afterStop = published.size

        gate.onSourceStarted()
        assertNull("consumed source must stay consumed across a stray START_FILE",
            gate.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF)))
        assertEquals(afterStop, published.size)
    }
}
