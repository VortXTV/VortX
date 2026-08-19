package com.vortx.android.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailSecondaryActionsPolicyTest {
    @Test
    fun `share uses imdb title url for tt ids`() {
        assertEquals(
            "https://www.imdb.com/title/tt0133093/",
            detailShareText(id = "tt0133093", title = "The Matrix"),
        )
    }

    @Test
    fun `share falls back to title for non imdb ids`() {
        assertEquals(
            "Spirited Away",
            detailShareText(id = "kitsu:12", title = "Spirited Away"),
        )
    }

    @Test
    fun `share falls back to title for malformed tt-like ids`() {
        val title = "Untrusted title"
        listOf(
            "tt",
            "ttfake",
            "tt0133093/../../redirect",
            "tt0133093\nInjected",
        ).forEach { id ->
            assertEquals("id=$id", title, detailShareText(id = id, title = title))
        }
    }

    @Test
    fun `credits disclosure starts expanded and toggles both ways`() {
        assertTrue(DETAIL_CREDITS_DEFAULT_EXPANDED)
        assertFalse(toggledDetailCredits(true))
        assertTrue(toggledDetailCredits(false))
    }
}
