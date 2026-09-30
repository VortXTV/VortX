package com.vortx.android.ui.viewmodel

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailEpisodeTargetPolicyTest {
    @Test
    fun `specials never outrank the first actual episode`() {
        val ordered = detailEpisodeTargetOrder(
            listOf(
                Episode("special", "Special", season = 0, episode = 1),
                Episode("s1e2", "Second", season = 1, episode = 2),
                Episode("s1e1", "First", season = 1, episode = 1),
            ),
        )

        assertEquals(listOf("s1e1", "s1e2"), ordered.map { it.id })
    }

    @Test
    fun `special-only titles retain their complete inventory`() {
        val ordered = detailEpisodeTargetOrder(
            listOf(
                Episode("special-2", "Second", season = 0, episode = 2),
                Episode("special-1", "First", season = 0, episode = 1),
            ),
        )

        assertEquals(listOf("special-1", "special-2"), ordered.map { it.id })
    }

    @Test
    fun `selection revision equality rejects a late old-language assembly`() {
        val old = DetailSourceSelectionRevision(requestGeneration = 4L, audioLanguage = "en")
        val newer = DetailSourceSelectionRevision(requestGeneration = 5L, audioLanguage = "fr")

        assertFalse(acceptsDetailSourceSelection(old, newer))
        assertTrue(acceptsDetailSourceSelection(newer, newer))
    }

    @Test
    fun `audio options follow source and addon order and omit unavailable settings`() {
        val groups = listOf(
            StreamGroup(
                addon = "French Addon",
                streams = listOf(StreamSource("fr", "French Addon", "WEB 1080p French", url = "https://fr")),
            ),
            StreamGroup(
                addon = "Japanese Addon",
                streams = listOf(StreamSource("ja", "Japanese Addon", "WEB 1080p Japanese", url = "https://ja")),
            ),
        )

        assertEquals(listOf("fr", "ja"), detailAudioLanguageOptions(groups).map { it.first })
        assertFalse(detailAudioLanguageOptions(groups).any { it.first == "en" })
    }

    @Test
    fun `subtitle-only language markers do not become audio choices`() {
        val groups = listOf(
            StreamGroup(
                addon = "Subs",
                streams = listOf(StreamSource("ko-subs", "Subs", "WEB 1080p korsub", url = "https://subs")),
            ),
        )

        assertTrue(detailAudioLanguageOptions(groups).isEmpty())
    }

    @Test
    fun `unsupported related types are not converted to movie lookups`() {
        assertFalse(canResolveRelatedDetail(MediaType.CHANNEL))
        assertFalse(canResolveRelatedDetail(MediaType.TV))
        assertTrue(canResolveRelatedDetail(MediaType.SERIES))
    }

    @Test
    fun `relation fence invalidation blocks an in-flight result after detail leaves`() {
        val fence = DetailNavigationFence()
        val stale = fence.begin()

        fence.invalidate()

        assertFalse(fence.accepts(stale))
        val current = fence.begin()
        assertTrue(fence.accepts(current))
    }
}
