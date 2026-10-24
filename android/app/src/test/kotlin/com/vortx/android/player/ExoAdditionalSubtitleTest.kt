package com.vortx.android.player

import com.vortx.android.model.ExternalSubtitle
import com.vortx.android.model.Playable
import org.junit.Assert.*
import org.junit.Test

/** Typed and legacy sidecars share the actual Exo normalization and append helpers. */
class ExoAdditionalSubtitleTest {
    @Test fun typedInitialTracksAndIndependentHeadersSurviveAppendingSelectedPoolFile() {
        val first = ExternalSubtitle("https://subs.example/a.vtt", mapOf("X-Sub" to "private-test-only"), "en", "English")
        val base = Playable("https://video.example/file.mkv", "Title",
            headers = mapOf("X-Video" to "different-test-only"),
            externalSubtitleTracks = listOf(first))
        val selected = "file:///private/cache/pool-2.srt"
        val updated = withAdditionalExternalSubtitle(base, selected)
        val actual = normalizedExternalSubtitles(updated)
        assertEquals(listOf(first.url, selected), actual.map { it.url })
        assertSame(first, actual.first())
        assertEquals(first.headers, actual.first().headers)
        assertTrue(actual.last().headers.isEmpty())
        assertEquals(base.url, updated.url); assertEquals(base.headers, updated.headers)
    }

    @Test fun legacyInitialUrlsAlsoSurviveConvertingToTypedListBeforeAppend() {
        val base = Playable("https://video.example/file.mkv", "Title",
            externalSubtitles = listOf("https://subs.example/legacy.vtt"))
        val selected = "file:///private/cache/selected.srt"
        val updated = withAdditionalExternalSubtitle(base, selected)
        assertTrue(updated.externalSubtitles.isEmpty())
        assertEquals(listOf(base.externalSubtitles.single(), selected), normalizedExternalSubtitles(updated).map { it.url })
    }

    @Test fun ignoredLegacyTracksAreNotActivatedWhenTypedTracksHavePrecedence() {
        val typed = ExternalSubtitle("https://subs.example/typed.vtt", language = "en")
        val base = Playable("https://video.example/file.mkv", "Title",
            externalSubtitles = listOf("https://subs.example/ignored.vtt"),
            externalSubtitleTracks = listOf(typed))
        val selected = "file:///private/cache/selected.srt"
        val updated = withAdditionalExternalSubtitle(base, selected)
        assertEquals(listOf(typed.url, selected), normalizedExternalSubtitles(updated).map { it.url })
        assertSame(typed, normalizedExternalSubtitles(updated).first())
        assertTrue(updated.externalSubtitles.isEmpty())
    }
}
