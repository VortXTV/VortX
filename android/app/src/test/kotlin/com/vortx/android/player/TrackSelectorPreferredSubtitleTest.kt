package com.vortx.android.player

import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.model.TrackPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
    fun shortcutSelectsFirstAvailableLanguageWithoutChangingAutomaticOffPolicy() {
        val preferences = TrackPreferences(
            listOf("en"), listOf("tr", "en"), TrackPreferences.ForcedPolicy.OFF, listOf("commentary"),
        )
        val english = PlayerTrack(1, "English", lang = "eng", selected = true)
        val commentary = PlayerTrack(2, "Commentary", lang = "tr")
        val turkish = PlayerTrack(3, "Turkish", lang = "tur")

        assertEquals(3, TrackSelector.preferredSubtitleShortcut(
            listOf(english, commentary, turkish), preferences, null, TrackSelector.SUBTITLE_OFF,
        ))
        assertEquals(TrackSelector.SUBTITLE_OFF, TrackSelector.preferredSubtitleShortcut(
            listOf(english, commentary), preferences, null, TrackSelector.SUBTITLE_OFF,
        ))
        assertEquals(TrackSelector.SUBTITLE_OFF, TrackSelector.select(
            listOf(english), listOf(english, commentary, turkish), preferences,
        ).subtitleId)
    }

    @Test
    fun shortcutTogglesAnActivePreferredPrimaryEvenWhenItIsForced() {
        val preferences = TrackPreferences(
            listOf("en"), listOf("en"), TrackPreferences.ForcedPolicy.FORCED, emptyList(),
        )
        val forced = PlayerTrack(1, "Forced English", lang = "eng", selected = true, forced = true)
        val full = PlayerTrack(2, "English", lang = "en")
        assertEquals(TrackSelector.SUBTITLE_OFF, TrackSelector.preferredSubtitleShortcut(
            listOf(forced, full), preferences, null, TrackSelector.SUBTITLE_OFF,
        ))
    }

    @Test
    fun shortcutNeverMistakesMpvSecondaryForPrimaryOrMovesItToThePrimarySlot() {
        val preferences = TrackPreferences(
            listOf("en"), listOf("en"), TrackPreferences.ForcedPolicy.ALWAYS, emptyList(),
        )
        val french = PlayerTrack(1, "French", lang = "fra", selected = true)
        val secondary = PlayerTrack(2, "English secondary", lang = "eng", selected = true)
        val english = PlayerTrack(3, "English", lang = "en")
        assertEquals(3, TrackSelector.preferredSubtitleShortcut(
            listOf(french, secondary, english), preferences, french.id, secondary.id,
        ))
        assertEquals(3, TrackSelector.preferredSubtitleShortcut(
            listOf(secondary, english), preferences, TrackSelector.SUBTITLE_OFF, secondary.id,
        ))
        assertNull(TrackSelector.preferredSubtitleShortcut(
            listOf(french, secondary), preferences, french.id, secondary.id,
        ))
    }

    @Test
    fun shortcutKeepsCurrentChoiceWhenNoLanguageMatchesOrIsConfigured() {
        val preferences = TrackPreferences(
            listOf("en"), listOf("tr"), TrackPreferences.ForcedPolicy.ALWAYS, emptyList(),
        )
        val english = PlayerTrack(1, "English", lang = "eng", selected = true)
        assertNull(TrackSelector.preferredSubtitleShortcut(
            listOf(english), preferences, null, TrackSelector.SUBTITLE_OFF,
        ))
        assertNull(TrackSelector.preferredSubtitleShortcut(
            listOf(english), preferences.copy(subtitleLanguages = emptyList()), null, TrackSelector.SUBTITLE_OFF,
        ))
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
