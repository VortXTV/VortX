package com.vortx.android.player

import com.vortx.android.player.EpisodeProgressionPolicy.Decision
import com.vortx.android.player.EpisodeProgressionPolicy.Intent
import com.vortx.android.player.EpisodeProgressionPolicy.Target
import com.vortx.android.player.EpisodeProgressionPolicy.Trigger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EpisodeProgressionPolicyTest {
    private val first = Target("series:1:2", generation = 4L)

    @Test
    fun `final stretch offers once at twenty seconds and EOF does not duplicate it`() {
        val policy = EpisodeProgressionPolicy()

        assertNull(policy.offer(first, 79_999L, 100_000L, ended = false))
        assertEquals(Trigger.FINAL_STRETCH, policy.offer(first, 80_000L, 100_000L, ended = false))
        assertNull(policy.offer(first, 90_000L, 100_000L, ended = false))
        assertNull(policy.offer(first, 100_000L, 100_000L, ended = true))
    }

    @Test
    fun `EOF offers when no final-stretch observation arrived`() {
        val policy = EpisodeProgressionPolicy()

        assertEquals(Trigger.EOF, policy.offer(first, 0L, 0L, ended = true))
        assertNull(policy.offer(first, 0L, 0L, ended = true))
    }

    @Test
    fun `manual and timed acceptance both advance only the current target`() {
        val policy = EpisodeProgressionPolicy()
        policy.offer(first, 80_000L, 100_000L, ended = false)

        assertEquals(Decision.ADVANCE, policy.decide(first, Intent.PLAY_NOW))
        assertEquals(Decision.STALE, policy.decide(first, Intent.AUTO_ADVANCE))
        assertEquals(Decision.STALE, policy.decide(first.copy(generation = 5L), Intent.AUTO_ADVANCE))
    }

    @Test
    fun `watch credits defers final offer until EOF`() {
        val policy = EpisodeProgressionPolicy()
        policy.offer(first, 80_000L, 100_000L, ended = false)

        assertEquals(Decision.WATCH_CREDITS, policy.decide(first, Intent.WATCH_CREDITS))
        assertNull(policy.offer(first, 90_000L, 100_000L, ended = false))
        assertEquals(Trigger.EOF, policy.offer(first, 100_000L, 100_000L, ended = true))
    }

    @Test
    fun `cancel prevents further offers for this generation`() {
        val policy = EpisodeProgressionPolicy()
        policy.offer(first, 80_000L, 100_000L, ended = false)

        assertEquals(Decision.CANCEL, policy.decide(first, Intent.CANCEL))
        assertNull(policy.offer(first, 100_000L, 100_000L, ended = true))
    }

    @Test
    fun `new generation rejects stale actions and may offer independently`() {
        val policy = EpisodeProgressionPolicy()
        policy.offer(first, 80_000L, 100_000L, ended = false)
        val replacement = first.copy(episodeId = "series:1:3", generation = 5L)

        assertEquals(Trigger.FINAL_STRETCH, policy.offer(replacement, 80_000L, 100_000L, ended = false))
        assertEquals(Decision.STALE, policy.decide(first, Intent.PLAY_NOW))
        assertEquals(Decision.ADVANCE, policy.decide(replacement, Intent.AUTO_ADVANCE))
    }
}
