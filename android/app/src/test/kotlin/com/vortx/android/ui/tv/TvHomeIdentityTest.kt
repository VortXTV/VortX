package com.vortx.android.ui.tv

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Test

class TvHomeIdentityTest {

    @Test
    fun `duplicate catalog identity is first wins`() {
        val first = Catalog("https://one.test|movie|popular", "One · Popular", listOf(movie("tt1", "First")))
        val duplicate = first.copy(title = "Late duplicate")

        assertEquals(listOf(first), tvHomeCatalogs(listOf(first, duplicate)))
    }

    @Test
    fun `same bare catalog from different addons remains distinct`() {
        val first = Catalog("https://one.test|movie|popular", "One · Popular", listOf(movie("tt1", "First")))
        val second = Catalog("https://two.test|movie|popular", "Two · Popular", listOf(movie("tt2", "Second")))

        assertEquals(listOf(first, second), tvHomeCatalogs(listOf(first, second)))
    }

    @Test
    fun `duplicate item identity is first wins but movie and series stay distinct`() {
        val movie = movie("tt1", "Movie")
        val duplicate = movie.copy(name = "Late duplicate")
        val series = MetaItem(id = "tt1", type = MediaType.SERIES, name = "Series")

        assertEquals(listOf(movie, series), tvHomeItems(listOf(movie, duplicate, series)))
        assertEquals("MOVIE|tt1", tvHomeItemKey(movie))
        assertEquals("SERIES|tt1", tvHomeItemKey(series))
    }

    @Test
    fun `profile catalog replacement keeps only a currently visible exact hero identity`() {
        val focused = movie("tt-shared", "Profile A movie")
        val refreshedFocused = focused.copy(name = "Profile A movie, refreshed")
        val retained = tvHomeHeroSelection(
            TvHomeHeroState(0L, tvHomeItemKey(focused)),
            0L,
            listOf(Catalog("profile-a", "Profile A", listOf(movie("tt-first", "First"), refreshedFocused))),
        )
        assertEquals(refreshedFocused, retained.item)
        assertEquals(tvHomeItemKey(refreshedFocused), retained.state.focusedKey)

        val sameIdDifferentType = MetaItem("tt-shared", MediaType.SERIES, "Profile B series")
        val profileBFirst = movie("tt-profile-b", "Profile B first")
        val replaced = tvHomeHeroSelection(
            retained.state,
            1L,
            listOf(Catalog("profile-b", "Profile B", listOf(profileBFirst, sameIdDifferentType))),
        )
        assertEquals(profileBFirst, replaced.item)
        assertEquals(TvHomeHeroState(1L, null), replaced.state)

        val lateProfileB = tvHomeHeroSelection(
            TvHomeHeroState(1L, tvHomeItemKey(profileBFirst)),
            1L,
            listOf(Catalog("profile-b", "Profile B", listOf(profileBFirst, sameIdDifferentType, focused))),
        )
        assertEquals(profileBFirst, lateProfileB.item)
    }

    @Test
    fun `owner generation clears old hero even when intermediate replacement frame is skipped`() {
        val oldFocused = movie("tt-old", "Old owner")
        val newFirst = movie("tt-new", "New owner")
        val staleLateOld = oldFocused.copy(name = "Late stale old owner")

        val oldState = TvHomeHeroState(7L, tvHomeItemKey(oldFocused))
        val generationFirst = tvHomeHeroSelection(
            previous = oldState,
            contentOwnerGeneration = 8L,
            catalogs = listOf(Catalog("old", "Old", listOf(oldFocused))),
        )
        val coalescedWithCommittedBoundary = tvHomeHeroSelection(
            previous = generationFirst.state,
            contentOwnerGeneration = 8L,
            catalogs = listOf(Catalog("new", "New", listOf(newFirst, staleLateOld))),
        )
        val coalescedWithSkippedBoundaryFrame = tvHomeHeroSelection(
            previous = oldState,
            contentOwnerGeneration = 8L,
            catalogs = listOf(Catalog("new", "New", listOf(newFirst, staleLateOld))),
        )

        assertEquals(oldFocused, generationFirst.item)
        assertEquals(TvHomeHeroState(8L, null), generationFirst.state)
        assertEquals(newFirst, coalescedWithCommittedBoundary.item)
        assertEquals(newFirst, coalescedWithSkippedBoundaryFrame.item)
        assertEquals(TvHomeHeroState(8L, null), coalescedWithCommittedBoundary.state)
        assertEquals(TvHomeHeroState(8L, null), coalescedWithSkippedBoundaryFrame.state)
    }

    private fun movie(id: String, name: String) = MetaItem(id = id, type = MediaType.MOVIE, name = name)
}
