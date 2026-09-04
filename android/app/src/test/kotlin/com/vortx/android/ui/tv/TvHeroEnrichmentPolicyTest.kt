package com.vortx.android.ui.tv

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.io.File
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvHeroEnrichmentPolicyTest {

    @Test
    fun `catalog preview metadata changes refresh the enrichment key even for the same media id`() {
        val original = completeHero(background = "https://art.example/old.jpg")
        val refreshed = original.copy(
            background = "https://art.example/new.jpg",
            trailerYouTubeId = "newTrailer",
        )

        assertNotEquals(original.heroPreviewKey(), refreshed.heroPreviewKey())
    }

    @Test
    fun `only a fully populated hero skips enrichment`() {
        assertFalse(completeHero().needsHeroEnrichment())
        assertTrue(completeHero().copy(logo = null).needsHeroEnrichment())
        assertTrue(completeHero().copy(background = null).needsHeroEnrichment())
        assertTrue(completeHero().copy(imdbRating = null).needsHeroEnrichment())
        assertTrue(completeHero().copy(genres = emptyList()).needsHeroEnrichment())
        assertTrue(completeHero().copy(year = null).needsHeroEnrichment())
    }

    @Test
    fun `ambient trailer setting is observed rather than captured once`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvAmbientHero.kt")

        assertTrue(source.contains("private fun rememberAutoplayTrailers"))
        assertTrue(source.contains("registerOnSharedPreferenceChangeListener"))
        assertTrue(source.contains("unregisterOnSharedPreferenceChangeListener"))
        assertTrue(source.contains("key == TrackPreferencesStore.KEY_AUTOPLAY_TRAILERS"))
        assertFalse(source.contains("remember { TrackPreferencesStore(context.applicationContext).autoplayTrailers }"))
    }

    private fun completeHero(background: String = "https://art.example/hero.jpg") = MetaItem(
        id = "tt123",
        type = MediaType.MOVIE,
        name = "Example",
        poster = "https://art.example/poster.jpg",
        background = background,
        logo = "https://art.example/logo.png",
        description = "A complete hero preview.",
        imdbRating = "8.2",
        genres = listOf("Drama"),
        year = "2026",
        trailerYouTubeId = "trailer",
    )

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
