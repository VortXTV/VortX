package com.vortx.android.player

import android.view.KeyEvent
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlayerKeyboardShortcutTest {
    @Test
    fun `only an unmodified alphabetic keyboard can invoke player shortcuts`() {
        assertEquals(PlayerKeyboardShortcut.PREFERRED_SUBTITLE, shortcut(KeyEvent.KEYCODE_C))
        assertEquals(PlayerKeyboardShortcut.TOGGLE_PLAYBACK, shortcut(KeyEvent.KEYCODE_SPACE))
        assertEquals(PlayerKeyboardShortcut.SKIP_SEGMENT, shortcut(KeyEvent.KEYCODE_S))
        assertEquals(PlayerKeyboardShortcut.PREVIOUS_EPISODE, shortcut(KeyEvent.KEYCODE_P))
        assertEquals(PlayerKeyboardShortcut.NEXT_EPISODE, shortcut(KeyEvent.KEYCODE_N))
        assertEquals(PlayerKeyboardShortcut.SEEK_PERCENT, shortcut(KeyEvent.KEYCODE_9))
        assertNull(shortcut(KeyEvent.KEYCODE_C, keyboard = false))
        assertNull(shortcut(KeyEvent.KEYCODE_C, alphabetic = false))
        assertNull(shortcut(KeyEvent.KEYCODE_SPACE, unmodified = false))
        assertNull(shortcut(KeyEvent.KEYCODE_ENTER))
        assertNull(shortcut(KeyEvent.KEYCODE_ESCAPE))
        assertNull(shortcut(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
    }

    @Test
    fun `TV directions are reserved for remote navigation while letter shortcuts still work`() {
        val directions = mapOf(
            KeyEvent.KEYCODE_DPAD_LEFT to PlayerKeyboardShortcut.SEEK_BACK,
            KeyEvent.KEYCODE_DPAD_RIGHT to PlayerKeyboardShortcut.SEEK_FORWARD,
            KeyEvent.KEYCODE_DPAD_UP to PlayerKeyboardShortcut.VOLUME_UP,
            KeyEvent.KEYCODE_DPAD_DOWN to PlayerKeyboardShortcut.VOLUME_DOWN,
        )
        directions.forEach { (key, expected) ->
            assertEquals(expected, shortcut(key))
            assertNull(shortcut(key, tv = true))
            assertNull(shortcut(key, alphabetic = false))
        }
        assertEquals(PlayerKeyboardShortcut.SEEK_BACK, shortcut(KeyEvent.KEYCODE_J, tv = true))
        assertEquals(PlayerKeyboardShortcut.SEEK_FORWARD, shortcut(KeyEvent.KEYCODE_L, tv = true))
        assertEquals(
            directions.values.toSet(),
            PlayerKeyboardShortcut.entries.filter { it.repeats }.toSet(),
        )
    }

    @Test
    fun `episode keys only choose unambiguous neighbours in the current season`() {
        val first = Episode("a", "One", 1, 1)
        val second = Episode("b", "Two", 1, 2)
        val third = Episode("c", "Three", 1, 3)
        val nextSeason = Episode("d", "Four", 2, 1)
        val episodes = listOf(nextSeason, third, first, second)
        val current = MediaRef(isSeries = true, season = 1, episode = 2)

        assertEquals(first, adjacentKeyboardEpisode(episodes, current, next = false))
        assertEquals(third, adjacentKeyboardEpisode(episodes, current, next = true))
        assertNull(adjacentKeyboardEpisode(episodes, current.copy(episode = 3), next = true))
        assertNull(adjacentKeyboardEpisode(episodes, current.copy(episode = 9), next = true))
        assertNull(adjacentKeyboardEpisode(episodes, current.copy(isSeries = false), next = true))
        assertNull(adjacentKeyboardEpisode(episodes + third.copy(id = "other"), current, next = true))
        assertNull(adjacentKeyboardEpisode(episodes + second.copy(id = "other"), current, next = true))
    }

    private fun shortcut(
        key: Int,
        keyboard: Boolean = true,
        unmodified: Boolean = true,
        alphabetic: Boolean = true,
        tv: Boolean = false,
    ) = playerKeyboardShortcut(key, keyboard, unmodified, alphabetic, tv)
}
