package com.vortx.android.ui

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Test

class HomeCatalogNormalizationTest {
    @Test
    fun `duplicate row and item identities are stable first wins`() {
        val firstMovie = item("tt1", MediaType.MOVIE, "First movie")
        val lateMovie = firstMovie.copy(name = "Late duplicate")
        val sameIdSeries = item("tt1", MediaType.SERIES, "Series")
        val firstRow = Catalog("catalog", "First row", listOf(firstMovie, lateMovie, sameIdSeries))
        val duplicateRow = Catalog("catalog", "Late row", listOf(item("tt2", MediaType.MOVIE, "Second")))
        val secondRow = Catalog("other", "Other row", listOf(item("tt3", MediaType.MOVIE, "Third")))

        val normalized = normalizeHomeCatalogs(listOf(firstRow, duplicateRow, secondRow))

        assertEquals(listOf("catalog", "other"), normalized.map { it.id })
        assertEquals("First row", normalized.first().title)
        assertEquals(listOf(firstMovie, sameIdSeries), normalized.first().items)
    }

    private fun item(id: String, type: MediaType, name: String) = MetaItem(id = id, type = type, name = name)
}
