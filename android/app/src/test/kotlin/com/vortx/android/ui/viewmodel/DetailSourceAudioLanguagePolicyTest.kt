package com.vortx.android.ui.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Test

class DetailSourceAudioLanguagePolicyTest {
    @Test
    fun `session language replaces the saved ranking chain without rewriting it`() {
        val saved = listOf("en", "ja", "en")

        assertEquals(listOf("fr"), detailSourceAudioLanguages("fr", saved))
        assertEquals(listOf("en", "ja", "en"), saved)
    }

    @Test
    fun `auto preserves the saved ranking chain exactly`() {
        val saved = listOf("en", "ja")

        assertEquals(saved, detailSourceAudioLanguages(null, saved))
        assertEquals(saved, detailSourceAudioLanguages("   ", saved))
    }
}
