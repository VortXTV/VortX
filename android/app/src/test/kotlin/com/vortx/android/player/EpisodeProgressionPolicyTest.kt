package com.vortx.android.player

import com.vortx.android.player.EpisodeProgressionPolicy.Decision
import com.vortx.android.player.EpisodeProgressionPolicy.Intent
import com.vortx.android.player.EpisodeProgressionPolicy.Target
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EpisodeProgressionPolicyTest {
    private val first = Target("series:1:2", generation = 4L)

    @Test
    fun `final stretch reports live remaining and retracts after seek out`() {
        val policy = EpisodeProgressionPolicy()

        assertNull(policy.observe(first, 79_999L, 100_000L, ended = false))
        assertEquals(19_500L, policy.observe(first, 80_500L, 100_000L, ended = false)?.remainingMs)
        assertNull(policy.observe(first, 60_000L, 100_000L, ended = false))
    }

    @Test
    fun `EOF offers when no final-stretch observation arrived`() {
        val policy = EpisodeProgressionPolicy()

        assertEquals(EpisodeProgressionPolicy.Phase.EOF, policy.observe(first, 0L, 0L, ended = true)?.phase)
    }

    @Test
    fun `manual and timed acceptance both advance only the current target`() {
        val policy = EpisodeProgressionPolicy()
        policy.observe(first, 80_000L, 100_000L, ended = false)

        assertEquals(Decision.ADVANCE, policy.decide(first, Intent.PLAY_NOW))
        assertEquals(Decision.STALE, policy.decide(first, Intent.AUTO_ADVANCE))
        assertEquals(Decision.STALE, policy.decide(first.copy(generation = 5L), Intent.AUTO_ADVANCE))
    }

    @Test
    fun `watch credits and cancel terminally suppress EOF and racing actions`() {
        val policy = EpisodeProgressionPolicy()
        policy.observe(first, 80_000L, 100_000L, ended = false)

        assertEquals(Decision.SUPPRESS, policy.decide(first, Intent.WATCH_CREDITS))
        assertNull(policy.observe(first, 100_000L, 100_000L, ended = true))
        assertEquals(Decision.STALE, policy.decide(first, Intent.AUTO_ADVANCE))
    }

    @Test
    fun `new generation rejects stale actions and may offer independently`() {
        val policy = EpisodeProgressionPolicy()
        policy.observe(first, 80_000L, 100_000L, ended = false)
        val replacement = first.copy(episodeId = "series:1:3", generation = 5L)

        assertEquals(EpisodeProgressionPolicy.Phase.FINAL_STRETCH, policy.observe(replacement, 80_000L, 100_000L, ended = false)?.phase)
        assertEquals(Decision.STALE, policy.decide(first, Intent.PLAY_NOW))
        assertEquals(EpisodeProgressionPolicy.Phase.EOF, policy.observe(replacement, 100_000L, 100_000L, ended = true)?.phase)
        assertEquals(Decision.ADVANCE, policy.decide(replacement, Intent.AUTO_ADVANCE))
    }

    @Test
    fun `a terminal prior generation cannot suppress a replacement identity`() {
        val policy = EpisodeProgressionPolicy()
        policy.observe(first, 80_000L, 100_000L, ended = false)
        assertEquals(Decision.SUPPRESS, policy.decide(first, Intent.CANCEL))

        val replacement = first.copy(episodeId = "series:2:1", generation = 5L)
        assertEquals(EpisodeProgressionPolicy.Phase.FINAL_STRETCH, policy.observe(replacement, 80_000L, 100_000L, ended = false)?.phase)
    }

    @Test
    fun `EOF is the only unattended advance admission`() {
        val policy = EpisodeProgressionPolicy()
        policy.observe(first, 80_000L, 100_000L, ended = false)

        assertEquals(Decision.STALE, policy.decide(first, Intent.AUTO_ADVANCE))
        assertEquals(EpisodeProgressionPolicy.Phase.EOF, policy.observe(first, 100_000L, 100_000L, ended = true)?.phase)
        assertEquals(Decision.ADVANCE, policy.decide(first, Intent.AUTO_ADVANCE))
    }
}
