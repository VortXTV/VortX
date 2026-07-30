package com.vortx.android.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class LanguagePrioritySemanticsTest {
    @Test
    fun `row actions name their target language`() {
        assertEquals(
            "Move French earlier",
            languageActionDescription(LanguagePriorityAction.EARLIER, "French"),
        )
        assertEquals(
            "Move French later",
            languageActionDescription(LanguagePriorityAction.LATER, "French"),
        )
        assertEquals(
            "Remove French",
            languageActionDescription(LanguagePriorityAction.REMOVE, "French"),
        )
    }
}
