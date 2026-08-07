package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TopPicksModelTest {
    @Test
    fun `merges seeds round robin and excludes owned duplicates`() = runBlocking {
        val calls = mutableListOf<String>()
        val model = TopPicksModel { seed ->
            calls += seed.id
            listOf(item("tt-owned"), item("tt-${seed.id}-a"), item("tt-shared"), item("tt-${seed.id}-b"))
        }
        val cw = listOf(item("tt1"), item("tt2"))
        val library = listOf(item("tt-owned"), item("tt3"), item("tt4"), item("tt5"), item("tt6"))

        val result = model.refresh(cw, library)

        assertEquals(listOf("tt1", "tt2", "tt-owned", "tt3", "tt4"), calls)
        assertEquals(
            listOf("tt-tt1-a", "tt-tt2-a", "tt-tt-owned-a", "tt-tt3-a", "tt-tt4-a", "tt-shared",
                "tt-tt1-b", "tt-tt2-b", "tt-tt-owned-b", "tt-tt3-b", "tt-tt4-b"),
            result.items.map { it.id },
        )
        assertTrue(result.changed)
    }

    @Test
    fun `unchanged history performs no second fetch`() = runBlocking {
        var calls = 0
        val model = TopPicksModel { calls += 1; listOf(item("tt9")) }

        assertTrue(model.refresh(listOf(item("tt1")), emptyList()).changed)
        assertFalse(model.refresh(listOf(item("tt1")), emptyList()).changed)
        assertEquals(1, calls)
    }

    @Test
    fun `rail is inserted after Continue Watching and never duplicated`() {
        val rows = listOf(
            Catalog("continue", "Continue Watching", listOf(item("tt1"))),
            Catalog("popular", "Popular", listOf(item("tt2"))),
        )
        val first = withTopPicksRail(rows, listOf(item("tt3")))
        val second = withTopPicksRail(first, listOf(item("tt4")))

        assertEquals(listOf("continue", TOP_PICKS_CATALOG_ID, "popular"), second.map { it.id })
        assertEquals(listOf("tt4"), second[1].items.map { it.id })
        assertEquals("Top Picks for you", second[1].title)
    }

    @Test
    fun `no eligible history clears existing picks`() = runBlocking {
        val model = TopPicksModel { listOf(item("tt9")) }
        model.refresh(listOf(item("tt1")), emptyList())

        val cleared = model.refresh(listOf(item("tmdb:1")), emptyList())

        assertTrue(cleared.changed)
        assertTrue(cleared.items.isEmpty())
    }

    @Test
    fun `changed history invalidates stale picks before the replacement fetch`() = runBlocking {
        val events = mutableListOf<String>()
        val model = TopPicksModel { seed ->
            events += "fetch-${seed.id}"
            listOf(item("tt-${seed.id}-pick"))
        }
        model.refresh(listOf(item("tt1")), emptyList())
        events.clear()

        val result = model.refresh(listOf(item("tt2")), emptyList()) {
            events += "cleared"
        }

        assertEquals(listOf("cleared", "fetch-tt2"), events)
        assertEquals(listOf("tt-tt2-pick"), result.items.map { it.id })
    }

    private fun item(id: String) = MetaItem(id, MediaType.MOVIE, id)
}
