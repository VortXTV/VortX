package com.vortx.android.ui.screens.profiles

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [normalizeCustomAvatar] is the pure port of Apple `ProfileEditorView`'s custom-avatar rule (first grapheme,
 * letters uppercased, emoji left as typed). These pin the letter/emoji/expansion branches so the Android avatar
 * a profile carries matches what Apple would have stored for the same keystrokes.
 */
class ProfileEditorControlsTest {

    @Test
    fun lowercaseLetterIsUppercased() {
        assertEquals("A", normalizeCustomAvatar("a"))
        assertEquals("Z", normalizeCustomAvatar("z"))
    }

    @Test
    fun alreadyUppercaseLetterIsUnchanged() {
        assertEquals("K", normalizeCustomAvatar("K"))
    }

    @Test
    fun digitIsUnchanged() {
        assertEquals("3", normalizeCustomAvatar("3"))
    }

    @Test
    fun emojiIsKeptAsTyped() {
        assertEquals("🔥", normalizeCustomAvatar("🔥")) // 🔥 (surrogate pair, not split)
    }

    @Test
    fun onlyTheFirstGraphemeIsTaken() {
        assertEquals("A", normalizeCustomAvatar("abc"))
        assertEquals("🔥", normalizeCustomAvatar("🔥🎬")) // 🔥🎬 -> 🔥
    }

    @Test
    fun expandingLetterIsKeptLowercaseNotSplit() {
        // 'ß'.uppercase() == "SS": the length guard keeps the original rather than emitting two characters.
        assertEquals("ß", normalizeCustomAvatar("ß"))
    }

    @Test
    fun emptyInputReturnsNull() {
        assertNull(normalizeCustomAvatar(""))
    }
}
