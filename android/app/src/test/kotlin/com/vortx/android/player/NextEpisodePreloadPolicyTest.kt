package com.vortx.android.player

import com.vortx.android.player.NextEpisodePreloadPolicy.AttemptKind
import com.vortx.android.player.NextEpisodePreloadPolicy.Completion
import com.vortx.android.player.NextEpisodePreloadPolicy.Target
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NextEpisodePreloadPolicyTest {
    private val first = Target("tt123:1:2", generation = 1L)

    @Test
    fun `first attempt waits for halfway or two durationless minutes`() {
        val policy = NextEpisodePreloadPolicy()

        assertNull(policy.evaluate(first, positionMs = 49_999L, durationMs = 100_000L, nowMs = 0L))
        assertEquals(
            AttemptKind.REGULAR,
            policy.evaluate(first, positionMs = 50_000L, durationMs = 100_000L, nowMs = 1L)?.kind,
        )

        policy.invalidate()
        assertNull(policy.evaluate(first, positionMs = 119_999L, durationMs = 0L, nowMs = 2L))
        assertEquals(
            AttemptKind.REGULAR,
            policy.evaluate(first, positionMs = 120_000L, durationMs = 0L, nowMs = 3L)?.kind,
        )
    }

    @Test
    fun `progress ticks cannot duplicate an active attempt`() {
        val policy = NextEpisodePreloadPolicy()
        val active = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 100L))

        repeat(100) { tick ->
            assertNull(policy.evaluate(first, 200_000L + tick, 400_000L, nowMs = 101L + tick))
        }

        assertTrue(policy.accepts(active))
        assertEquals(1, policy.regularAttempts)
    }

    @Test
    fun `failed attempts retry only after twenty and sixty seconds`() {
        val policy = NextEpisodePreloadPolicy()
        val firstAttempt = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 0L))

        assertEquals(Completion.RETRY_SCHEDULED, policy.complete(firstAttempt, success = false, nowMs = 1_000L))
        assertNull(policy.evaluate(first, 210_000L, 400_000L, nowMs = 20_999L))
        val second = requireNotNull(policy.evaluate(first, 210_000L, 400_000L, nowMs = 21_000L))
        assertEquals(2, second.sequence)

        assertEquals(Completion.RETRY_SCHEDULED, policy.complete(second, success = false, nowMs = 22_000L))
        assertNull(policy.evaluate(first, 140_000L, 400_000L, nowMs = 81_999L))
        val third = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 82_000L))
        assertEquals(3, third.sequence)
        assertEquals(AttemptKind.REGULAR, third.kind)

        assertEquals(Completion.EXHAUSTED, policy.complete(third, success = false, nowMs = 83_000L))
        assertNull(policy.evaluate(first, 299_999L, 400_000L, nowMs = Long.MAX_VALUE))
        assertEquals(
            AttemptKind.NEAR_CREDITS,
            policy.evaluate(first, 300_000L, 400_000L, nowMs = Long.MAX_VALUE)?.kind,
        )
    }

    @Test
    fun `timed out regular attempt follows the same retry schedule`() {
        val policy = NextEpisodePreloadPolicy()
        val timedOut = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 1_000L))

        assertNull(policy.evaluate(first, 210_000L, 400_000L, nowMs = timedOut.deadlineMs - 1L))
        val retry = requireNotNull(policy.evaluate(first, 210_000L, 400_000L, nowMs = timedOut.deadlineMs))

        assertEquals(AttemptKind.REGULAR, retry.kind)
        assertEquals(2, retry.sequence)
    }

    @Test
    fun `credits preempt a regular attempt exactly once`() {
        val policy = NextEpisodePreloadPolicy()
        val regular = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 0L))

        val credits = requireNotNull(policy.evaluate(first, 301_000L, 400_000L, nowMs = 1_000L))

        assertEquals(AttemptKind.NEAR_CREDITS, credits.kind)
        assertEquals(2, credits.sequence)
        assertEquals(Completion.STALE, policy.complete(regular, success = true, nowMs = 1_001L))
        assertEquals(Completion.EXHAUSTED, policy.complete(credits, success = false, nowMs = 1_002L))
        assertNull(policy.evaluate(first, 399_000L, 400_000L, nowMs = Long.MAX_VALUE))
        assertTrue(policy.nearCreditsAttempted)
    }

    @Test
    fun `successful completion suppresses later ticks and stale completions`() {
        val policy = NextEpisodePreloadPolicy()
        val attempt = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 0L))

        assertEquals(Completion.READY, policy.complete(attempt, success = true, nowMs = 1L))
        assertTrue(policy.isReady(first))
        assertNull(policy.evaluate(first, 399_000L, 400_000L, nowMs = 2L))
        assertEquals(Completion.STALE, policy.complete(attempt, success = false, nowMs = 3L))
    }

    @Test
    fun `target generation change invalidates old work and restarts sequence`() {
        val policy = NextEpisodePreloadPolicy()
        val old = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 0L))
        val replacement = first.copy(generation = 2L)
        val current = requireNotNull(policy.evaluate(replacement, 200_000L, 400_000L, nowMs = 1L))

        assertNotEquals(old.target, current.target)
        assertEquals(1, current.sequence)
        assertEquals(Completion.STALE, policy.complete(old, success = true, nowMs = 2L))
        assertTrue(policy.accepts(current))
    }

    @Test
    fun `warm failure reserves only the final credits attempt`() {
        val policy = NextEpisodePreloadPolicy()
        val regular = requireNotNull(policy.evaluate(first, 200_000L, 400_000L, nowMs = 0L))
        assertEquals(Completion.READY, policy.complete(regular, success = true, nowMs = 1L))

        assertTrue(policy.warmFailed(first))
        assertFalse(policy.isReady(first))
        assertNull(policy.evaluate(first, 250_000L, 400_000L, nowMs = 2L))
        val credits = requireNotNull(policy.evaluate(first, 300_000L, 400_000L, nowMs = 3L))

        assertEquals(AttemptKind.NEAR_CREDITS, credits.kind)
        assertFalse(policy.warmFailed(first))
    }

    @Test
    fun `durationless credits window opens at five minutes`() {
        val policy = NextEpisodePreloadPolicy()
        val regular = requireNotNull(policy.evaluate(first, 120_000L, 0L, nowMs = 0L))
        assertEquals(Completion.RETRY_SCHEDULED, policy.complete(regular, success = false, nowMs = 1L))

        assertNull(policy.evaluate(first, 299_999L, 0L, nowMs = 2L))
        assertEquals(
            AttemptKind.NEAR_CREDITS,
            policy.evaluate(first, 300_000L, 0L, nowMs = 3L)?.kind,
        )
    }

    @Test
    fun `invalid progress cannot schedule work`() {
        val policy = NextEpisodePreloadPolicy()

        assertNull(policy.evaluate(first, -1L, 100_000L, nowMs = 0L))
        assertNull(policy.evaluate(first, 60_000L, -1L, nowMs = 1L))
    }
}
