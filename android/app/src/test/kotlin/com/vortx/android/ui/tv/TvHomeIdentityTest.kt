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

    private fun movie(id: String, name: String) = MetaItem(id = id, type = MediaType.MOVIE, name = name)
}
