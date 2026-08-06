package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BecauseYouWatchedModelTest {
    @Test
    fun `uses newest continue watching seed and merges recommendations round robin`() = runBlocking {
        val model = BecauseYouWatchedModel { seed ->
            listOf(item("tt-owned"), item("tt-${seed.id}-a"), item("tt-shared"), item("tt-${seed.id}-b"))
        }

        val result = model.refresh(
            continueWatching = listOf(item("tt1", "Newest"), item("tt2", "Older")),
            library = listOf(item("tt-owned")),
        )

        assertEquals("Because you watched Newest", result.rail?.title)
        assertEquals(
            listOf("tt-tt1-a", "tt-tt2-a", "tt-tt-owned-a", "tt-shared", "tt-tt1-b", "tt-tt2-b", "tt-tt-owned-b"),
            result.rail?.items?.map(MetaItem::id),
        )
    }

    @Test
    fun `unchanged history reuses cache without a second fetch`() = runBlocking {
        var calls = 0
        val model = BecauseYouWatchedModel { calls += 1; listOf(item("tt9")) }

        assertTrue(model.refresh(listOf(item("tt1")), emptyList()).changed)
        assertFalse(model.refresh(listOf(item("tt1")), emptyList()).changed)
        assertEquals(1, calls)
    }

    @Test
    fun `changed history clears stale personalized rail before fetching`() = runBlocking {
        val events = mutableListOf<String>()
        val model = BecauseYouWatchedModel { seed ->
            events += "fetch:${seed.id}"
            listOf(item("tt-${seed.id}"))
        }
        model.refresh(listOf(item("tt1")), emptyList())
        events.clear()

        model.refresh(listOf(item("tt2")), emptyList()) { events += "clear" }

        assertEquals(listOf("clear", "fetch:tt2"), events)
    }

    @Test
    fun `cancellation is never swallowed by fail soft seed fetch`() {
        val model = BecauseYouWatchedModel { throw CancellationException("stop") }

        assertThrows(CancellationException::class.java) {
            runBlocking { model.refresh(listOf(item("tt1")), emptyList()) }
        }
    }

    @Test
    fun `home helpers produce requested personalized ordering without duplicates`() {
        val addon = Catalog("addon", "Popular", listOf(item("tt0")))
        val top = withTopPicksRail(listOf(Catalog("continue", "Continue", listOf(item("tt1"))), addon), listOf(item("tt2")))
        val because = withBecauseYouWatchedRail(
            top,
            Catalog(BECAUSE_YOU_WATCHED_CATALOG_ID, "Because", listOf(item("tt3"))),
        )
        val external = withExternalWatchlistRails(because, listOf(item("tt4")), listOf(item("tt5")))

        assertEquals(
            listOf(
                "continue",
                TOP_PICKS_CATALOG_ID,
                BECAUSE_YOU_WATCHED_CATALOG_ID,
                TRAKT_WATCHLIST_CATALOG_ID,
                SIMKL_WATCHLIST_CATALOG_ID,
                "addon",
            ),
            external.map(Catalog::id),
        )
    }

    private fun item(id: String, name: String = id) = MetaItem(id, MediaType.MOVIE, name)
}
