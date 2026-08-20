package com.vortx.android.ui.tv

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Test

class TvDetailSimilarMergeTest {

    @Test
    fun `related rail retains recommendation order while adding unique catalog matches`() {
        val first = item("tt-first")
        val duplicate = item("tt-duplicate")
        val fromCatalog = item("tt-catalog")

        assertEquals(
            listOf(first, duplicate, fromCatalog),
            mergeTvSimilar(
                recommendations = listOf(first, duplicate),
                catalogMatches = listOf(duplicate, item("tt-seed"), fromCatalog),
                excludingId = "tt-seed",
            ),
        )
    }

    private fun item(id: String) = MetaItem(id = id, type = MediaType.MOVIE, name = id)
}
