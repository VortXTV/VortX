package com.vortx.android.player

import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.model.TrackPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackSelectorPreferredSubtitleTest {
    private data class Row(val language: String)

    @Test
    fun addOnPreferenceKeepsForcedAndOffPolicyAndMatchesAudioChain() {
        val audio = listOf(PlayerTrack(1, "English", lang = "eng"))
        val subs = listOf(PlayerTrack(2, "English", lang = "en"))
        val preferences = TrackPreferences(listOf("en"), listOf("en"), TrackPreferences.ForcedPolicy.ALWAYS, emptyList())
        assertFalse(TrackSelector.wantsExternalSubtitle(audio, subs, preferences))
        assertTrue(TrackSelector.wantsExternalSubtitle(audio, subs, preferences, preferAddonSubtitles = true))
        for (policy in listOf(TrackPreferences.ForcedPolicy.OFF, TrackPreferences.ForcedPolicy.FORCED)) {
            assertFalse(TrackSelector.wantsExternalSubtitle(audio, subs, preferences.copy(forcedPolicy = policy),
                preferAddonSubtitles = true))
        }
        val unmatchedAudio = preferences.copy(audioLanguages = listOf("ja"), forcedPolicy = TrackPreferences.ForcedPolicy.OFF)
        assertTrue(TrackSelector.wantsExternalSubtitle(audio, emptyList(), unmatchedAudio, preferAddonSubtitles = true))
        assertFalse(TrackSelector.wantsExternalSubtitle(audio, emptyList(), unmatchedAudio,
            preferAddonSubtitles = true, matchAudioSub = true))
    }

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
