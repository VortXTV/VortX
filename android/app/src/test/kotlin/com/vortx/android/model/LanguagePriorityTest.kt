package com.vortx.android.model

import org.junit.Assert.assertEquals
import org.junit.Test

class LanguagePriorityTest {
    @Test
    fun `normalization keeps every distinct language in order`() {
        assertEquals(
            listOf("en", "fr", "hi", "ja"),
            LanguagePriority.normalized(listOf(" EN ", "fr", "hi", "fr", "JA")),
        )
    }

    @Test
    fun `adding a third language does not truncate existing priorities`() {
        assertEquals(
            listOf("en", "fr", "hi"),
            LanguagePriority.add(listOf("en", "fr"), "hi"),
        )
    }

    @Test
    fun `moving a language changes only its priority`() {
        assertEquals(
            listOf("en", "hi", "fr", "ja"),
            LanguagePriority.move(listOf("en", "fr", "hi", "ja"), index = 2, delta = -1),
        )
    }

    @Test
    fun `removing a language preserves at least one preference`() {
        assertEquals(listOf("en"), LanguagePriority.remove(listOf("en"), index = 0))
        assertEquals(
            listOf("en", "hi"),
            LanguagePriority.remove(listOf("en", "fr", "hi"), index = 1),
        )
    }
}
