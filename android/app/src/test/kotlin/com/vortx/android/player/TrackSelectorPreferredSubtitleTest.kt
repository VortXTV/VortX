package com.vortx.android.player

import com.vortx.android.model.TrackPreferencesStore
import org.junit.Assert.assertEquals
import org.junit.Test

class TrackSelectorPreferredSubtitleTest {
    private data class Row(val language: String)

    @Test
    fun enabledFilterKeepsPreferredAliasesAndUnknownRows() {
        val rows = listOf(Row("eng"), Row("tur"), Row("tr-TR"), Row("und"), Row("unknown"), Row(""))

        val kept = TrackSelector.keepingPreferredSubtitleLanguages(
            items = rows,
            enabled = true,
            preferredLanguages = listOf("tr"),
            language = Row::language,
        )

        assertEquals(listOf("tur", "tr-TR", "und", "unknown", ""), kept.map { it.language })
    }

    @Test
    fun disabledFilterIsAStableNoOp() {
        val rows = listOf(Row("en"), Row("fr"))
        assertEquals(
            rows,
            TrackSelector.keepingPreferredSubtitleLanguages(rows, false, listOf("tr"), Row::language),
        )
        assertEquals("stremiox.tracks.subOnlyPreferred", TrackPreferencesStore.KEY_SUB_ONLY_PREFERRED)
    }
}
