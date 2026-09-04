package com.vortx.android.ui.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneHeroPolicyTest {
    @Test fun `candidate pool preserves editorial order and de-duplicates typed identities`() {
        val movie = item("same", MediaType.MOVIE, "Movie")
        val series = item("same", MediaType.SERIES, "Series")
        val candidates = PhoneHeroPolicy.candidates(listOf(
            Catalog("continue", "Continue", listOf(movie, movie.copy(name = "Late duplicate"))),
            Catalog("popular", "Popular", listOf(series, item("third", MediaType.MOVIE, "Third"))),
        ))
        assertEquals(listOf("Movie", "Series", "Third"), candidates.map { it.name })
    }

    @Test fun `initial selection keeps visible identity through catalog refresh`() {
        val candidates = listOf(item("one"), item("two"), item("three"))
        assertEquals(1, PhoneHeroPolicy.initialIndex(candidates, PhoneHeroPolicy.identity(candidates[1])))
        assertEquals(0, PhoneHeroPolicy.initialIndex(candidates, "movie:gone"))
    }

    @Test fun `rotation wraps and only runs when motion and interaction permit it`() {
        assertEquals(0, PhoneHeroPolicy.nextIndex(2, 3, forward = true))
        assertEquals(2, PhoneHeroPolicy.nextIndex(0, 3, forward = false))
        assertTrue(PhoneHeroPolicy.shouldRotate(2, reducedMotion = false, interactionHeld = false))
        assertFalse(PhoneHeroPolicy.shouldRotate(1, reducedMotion = false, interactionHeld = false))
        assertFalse(PhoneHeroPolicy.shouldRotate(2, reducedMotion = true, interactionHeld = false))
        assertFalse(PhoneHeroPolicy.shouldRotate(2, reducedMotion = false, interactionHeld = true))
    }

    @Test fun `enrichment cannot overwrite a newer hero generation`() {
        assertTrue(PhoneHeroPolicy.acceptsEnrichment("movie:one", "movie:one", 4, 4))
        assertFalse(PhoneHeroPolicy.acceptsEnrichment("movie:one", "movie:two", 4, 5))
        assertFalse(PhoneHeroPolicy.acceptsEnrichment("movie:one", "movie:one", 4, 5))
    }

    @Test fun `failed logo falls back to title and a new URL is allowed to render`() {
        assertTrue(PhoneHeroPolicy.shouldShowLogo("https://art/logo-a.png", failedForUrl = null))
        assertFalse(PhoneHeroPolicy.shouldShowLogo("https://art/logo-a.png", failedForUrl = "https://art/logo-a.png"))
        assertTrue(PhoneHeroPolicy.shouldShowLogo("https://art/logo-b.png", failedForUrl = "https://art/logo-a.png"))
    }

    private fun item(id: String, type: MediaType = MediaType.MOVIE, name: String = id) =
        MetaItem(id = id, type = type, name = name)
}
