package com.vortx.android.mediaserver

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

class MediaServerCatalogsModelTest {
    @Test
    fun `disconnected model is dormant`() = runBlocking {
        val source = FakeSource(generation = null)

        assertTrue(MediaServerCatalogsModel(source).refresh().rails.isEmpty())
        assertEquals(0, source.fetches)
    }

    @Test
    fun `successful empty result is cached for thirty minutes`() = runBlocking {
        var now = 1_000L
        val source = FakeSource(3L, Result.success(emptyList()))
        val model = MediaServerCatalogsModel(source) { now }

        model.refresh()
        now += 29 * 60 * 1000L
        model.refresh()

        assertEquals(1, source.fetches)
    }

    @Test
    fun `transient failure retains rails only for the same configuration`() = runBlocking {
        var now = 0L
        val source = FakeSource(4L, Result.success(listOf(rail("a"))))
        val model = MediaServerCatalogsModel(source) { now }
        assertEquals(listOf("a"), model.refresh().rails.map(Catalog::title))

        now += 31 * 60 * 1000L
        source.response = Result.failure(IllegalStateException("offline"))
        assertEquals(listOf("a"), model.refresh().rails.map(Catalog::title))

        source.generation = 5L
        val switched = model.refresh()
        assertTrue(switched.rails.isEmpty())
        assertTrue(switched.changed)
    }

    @Test
    fun `configuration change during fetch discards the old servers response`() = runBlocking {
        val source = FakeSource(6L, Result.success(listOf(rail("old"))))
        source.afterFetch = { source.generation = 7L }

        val result = MediaServerCatalogsModel(source).refresh()

        assertTrue(result.rails.isEmpty())
        assertFalse(result.changed)
    }

    @Test
    fun `clear during fetch wins and cancellation propagates`() {
        val source = FakeSource(8L, Result.success(listOf(rail("old"))))
        lateinit var model: MediaServerCatalogsModel
        model = MediaServerCatalogsModel(source)
        source.afterFetch = { model.clear() }
        assertTrue(runBlocking { model.refresh() }.rails.isEmpty())

        source.afterFetch = null
        source.failure = CancellationException("stop")
        assertThrows(CancellationException::class.java) { runBlocking { model.refresh() } }
    }

    @Test
    fun `server rails follow external watchlists and replace by prefix`() {
        val rows = listOf(
            Catalog("vortx.home.simklWatchlist", "SIMKL", listOf(item("tt1"))),
            Catalog("addon", "Popular", listOf(item("tt2"))),
            Catalog("${MEDIA_SERVER_CATALOG_PREFIX}stale:movie", "Stale", listOf(item("tt3"))),
        )

        val result = withMediaServerRails(rows, listOf(rail("Fresh")))

        assertEquals(listOf("SIMKL", "Fresh", "Popular"), result.map(Catalog::title))
    }

    private class FakeSource(
        var generation: Long?,
        var response: Result<List<Catalog>> = Result.success(emptyList()),
    ) : MediaServerCatalogSource {
        var fetches = 0
        var afterFetch: (() -> Unit)? = null
        var failure: Throwable? = null

        override fun configurationGeneration(): Long? = generation

        override suspend fun fetch(expectedGeneration: Long): Result<List<Catalog>> {
            fetches += 1
            failure?.let { throw it }
            return response.also { afterFetch?.invoke() }
        }
    }

    private fun rail(title: String) =
        Catalog("${MEDIA_SERVER_CATALOG_PREFIX}$title:movie", title, listOf(item("tt9")))

    private fun item(id: String) = MetaItem(id, MediaType.MOVIE, id)
}
