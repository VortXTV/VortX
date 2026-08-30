package com.vortx.android.player.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvTerminalTransitionTest {
    @Test
    fun `native payload maps every declared reason and preserves error`() {
        assertEquals(MpvTerminalReason.EOF, MpvTerminalEvent.fromNative(0, 0).reason)
        assertEquals(MpvTerminalReason.STOP, MpvTerminalEvent.fromNative(2, 0).reason)
        assertEquals(MpvTerminalReason.QUIT, MpvTerminalEvent.fromNative(3, 0).reason)
        assertEquals(MpvTerminalReason.ERROR, MpvTerminalEvent.fromNative(4, -13).reason)
        assertEquals(MpvTerminalReason.REDIRECT, MpvTerminalEvent.fromNative(5, 0).reason)
        // client.h: "Unknown values should be treated as unknown" -- fail-safe mapping, never guessed.
        assertEquals(MpvTerminalReason.UNKNOWN, MpvTerminalEvent.fromNative(99, -7).reason)
        assertEquals(-13, MpvTerminalEvent.fromNative(4, -13).nativeError)
    }

    @Test
    fun `error payload is carried only for genuine error terminations`() {
        // client.h documents mpv_event_end_file.error as present ONLY for ERROR (and 0 otherwise),
        // so a non-ERROR reason must not manufacture an error code out of the field.
        assertNull(MpvTerminalEvent.fromNative(4, 0).nativeError)
        assertNull(MpvTerminalEvent.fromNative(0, 0).nativeError)
        assertNull(MpvTerminalEvent.fromNative(2, -13).nativeError)
    }

    @Test
    fun `natural eof ends exactly once`() {
        val active = MpvTerminalState.initialSource()
        val ended = active.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))

        assertEquals(MpvTerminalReason.EOF, ended.reason)
        assertTrue(ended.hasEnded)
        assertFalse(ended.hasError)
        assertEquals(ended, ended.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF)))
    }

    @Test
    fun `midstream native error remains retryable and preserves its code`() {
        val failed = MpvTerminalState.initialSource().onTerminal(
            MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -13),
        )

        assertEquals(MpvTerminalReason.ERROR, failed.reason)
        assertFalse(failed.hasEnded)
        assertTrue(failed.hasError)
        assertEquals(-13, failed.nativeError)
    }

    @Test
    fun `manual stop never marks watched or becomes an error`() {
        val stopped = MpvTerminalState.initialSource().onTerminal(
            MpvTerminalEvent(MpvTerminalReason.STOP),
        )

        assertEquals(MpvTerminalReason.STOP, stopped.reason)
        assertFalse(stopped.hasEnded)
        assertFalse(stopped.hasError)
    }

    @Test
    fun `quit never marks watched or becomes an error`() {
        val quit = MpvTerminalState.initialSource().onTerminal(
            MpvTerminalEvent(MpvTerminalReason.QUIT),
        )

        assertEquals(MpvTerminalReason.QUIT, quit.reason)
        assertFalse(quit.hasEnded)
        assertFalse(quit.hasError)
    }

    @Test
    fun `redirect never marks watched or becomes an error`() {
        val redirected = MpvTerminalState.initialSource().onTerminal(
            MpvTerminalEvent(MpvTerminalReason.REDIRECT),
        )

        assertEquals(MpvTerminalReason.REDIRECT, redirected.reason)
        assertFalse(redirected.hasEnded)
        assertFalse(redirected.hasError)

        val ended = redirected.onSourceStarted().onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))
        assertTrue(ended.hasEnded)
    }

    @Test
    fun `multiple redirect hops remain open until a real terminal`() {
        val active = MpvTerminalState.initialSource()
            .onTerminal(MpvTerminalEvent(MpvTerminalReason.REDIRECT))
            .onSourceStarted()
            .onTerminal(MpvTerminalEvent(MpvTerminalReason.REDIRECT))
            .onSourceStarted()

        val failed = active.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -5))
        assertTrue(failed.hasError)
        assertEquals(-5, failed.nativeError)
    }

    @Test
    fun `source replacement suppresses the old terminal until the new source starts`() {
        val replacing = MpvTerminalState.initialSource().onSourceReplacement()
        val oldTypedStop = replacing.onTerminal(MpvTerminalEvent(MpvTerminalReason.STOP))
        val oldEof = oldTypedStop.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))
        val newFailure = oldEof.onSourceStarted().onTerminal(
            MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -5),
        )

        assertNull(oldEof.reason)
        assertFalse(oldEof.hasEnded)
        assertFalse(oldEof.hasError)
        assertEquals(MpvTerminalReason.ERROR, newFailure.reason)
        assertFalse(newFailure.hasEnded)
        assertTrue(newFailure.hasError)
        assertEquals(-5, newFailure.nativeError)
    }

    @Test
    fun `unknown reason after source start fails safe as retryable error without ending`() {
        // A reason code this libmpv generation does not define (client.h: treat as unknown) must
        // never mark watched and never pass silently: fail safe as a retryable error.
        val unknown = MpvTerminalState.initialSource()
            .onSourceStarted()
            .onTerminal(MpvTerminalEvent.fromNative(99, -7))

        assertEquals(MpvTerminalReason.UNKNOWN, unknown.reason)
        assertFalse(unknown.hasEnded)
        assertTrue(unknown.hasError)
    }

    @Test
    fun `duplicate callbacks cannot change the first terminal classification`() {
        val first = MpvTerminalState.initialSource().onTerminal(
            MpvTerminalEvent(MpvTerminalReason.ERROR, nativeError = -13),
        )
        val duplicateEof = first.onTerminal(MpvTerminalEvent(MpvTerminalReason.EOF))
        val duplicateStop = duplicateEof.onTerminal(MpvTerminalEvent(MpvTerminalReason.STOP))

        assertEquals(first, duplicateEof)
        assertEquals(first, duplicateStop)
        assertEquals(MpvTerminalReason.ERROR, duplicateStop.reason)
        assertFalse(duplicateStop.hasEnded)
        assertTrue(duplicateStop.hasError)
        assertEquals(-13, duplicateStop.nativeError)
    }
}
