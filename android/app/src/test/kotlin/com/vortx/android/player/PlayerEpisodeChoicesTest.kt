package com.vortx.android.player

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerEpisodeChoicesTest {
    private val episodes = listOf(
        Episode("s2e1", "Season two", 2, 1),
        Episode("s1e2", "Finale", 1, 2),
        Episode("s1e1", "Pilot", 1, 1),
    )

    @Test
    fun `cross season inventory is ordered and selects accepted player identity`() {
        val choices = playerEpisodeChoices(
            episodes,
            MediaRef(isSeries = true, imdb = "tt1", season = 1, episode = 2),
        )

        assertEquals(listOf("s1e1", "s1e2", "s2e1"), choices.map { it.episode.id })
        assertEquals(listOf("s1e2"), choices.filter { it.selected }.map { it.episode.id })
    }

    @Test
    fun `unmapped player identity fails closed rather than choosing an arbitrary episode`() {
        assertTrue(playerEpisodeChoices(episodes, MediaRef(isSeries = false, imdb = "tt1")).isEmpty())
    }
}
