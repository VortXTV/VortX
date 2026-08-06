package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class ExternalWatchlistModelsTest {
    @Test
    fun `dormant disconnected model makes no request`() = runBlocking {
        val source = FakeSource(epoch = null)
        val result = TraktRailsModel(source).refresh()

        assertTrue(result.items.isEmpty())
        assertEquals(0, source.fetches)
    }

    @Test
    fun `successful empty result is throttled instead of request storming`() = runBlocking {
        var now = 1_000L
        val source = FakeSource(epoch = 4L, response = Result.success(emptyList()))
        val model = TraktRailsModel(source) { now }

        model.refresh()
        now += 30_000L
        model.refresh()

        assertEquals(1, source.fetches)
    }

    @Test
    fun `transient failure preserves populated rail only inside same session`() = runBlocking {
        val source = FakeSource(epoch = 7L, response = Result.success(listOf(item("tt1"))))
        var now = 0L
        val model = TraktRailsModel(source) { now }
        assertEquals(listOf("tt1"), model.refresh().items.map(MetaItem::id))

        now += 301_000L
        source.response = Result.failure(IllegalStateException("offline"))
        assertEquals(listOf("tt1"), model.refresh().items.map(MetaItem::id))

        source.epoch = 8L
        val switched = model.refresh()
        assertTrue(switched.items.isEmpty())
        assertTrue(switched.changed)
    }

    @Test
    fun `response from session that changed during fetch is discarded`() = runBlocking {
        val source = FakeSource(epoch = 10L, response = Result.success(listOf(item("tt2"))))
        source.afterFetch = { source.epoch = 11L }

        val result = SimklRailsModel(source = source).refresh()

        assertTrue(result.items.isEmpty())
        assertFalse(result.changed)
    }

    @Test
    fun `disconnect clear during fetch wins over stale response`() = runBlocking {
        val source = FakeSource(epoch = 21L, response = Result.success(listOf(item("tt21"))))
        lateinit var model: TraktRailsModel
        model = TraktRailsModel(source)
        source.afterFetch = {
            source.epoch = null
            model.clear()
        }

        assertTrue(model.refresh().items.isEmpty())
    }

    @Test
    fun `cancellation is never converted into a fail-soft result`() {
        val source = FakeSource(epoch = 12L).apply { failure = CancellationException("cancelled") }

        assertThrows(CancellationException::class.java) {
            runBlocking { TraktRailsModel(source).refresh() }
        }
    }

    @Test
    fun `external rails follow top picks and keep provider labels separate`() {
        val rows = listOf(
            Catalog("continue", "Continue Watching", listOf(item("tt0"))),
            Catalog(TOP_PICKS_CATALOG_ID, "Top Picks for you", listOf(item("tt9"))),
            Catalog("addon", "Popular", listOf(item("tt8"))),
        )

        val result = withExternalWatchlistRails(rows, listOf(item("tt1")), listOf(item("tt2")))

        assertEquals(
            listOf("continue", TOP_PICKS_CATALOG_ID, TRAKT_WATCHLIST_CATALOG_ID, SIMKL_WATCHLIST_CATALOG_ID, "addon"),
            result.map(Catalog::id),
        )
        assertEquals("Trakt Watchlist", result[2].title)
        assertEquals("SIMKL Watchlist", result[3].title)
    }

    private class FakeSource(
        var epoch: Long?,
        var response: Result<List<MetaItem>> = Result.success(emptyList()),
    ) : ExternalWatchlistSource {
        var fetches = 0
        var afterFetch: (() -> Unit)? = null
        var failure: Throwable? = null

        override fun sessionEpoch(): Long? = epoch

        override suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>> {
            fetches += 1
            failure?.let { throw it }
            return response.also { afterFetch?.invoke() }
        }
    }

    private fun item(id: String) = MetaItem(id, MediaType.MOVIE, id)
}
