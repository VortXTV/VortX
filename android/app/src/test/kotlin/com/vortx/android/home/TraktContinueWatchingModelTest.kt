package com.vortx.android.home

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Catalog
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TraktContinueWatchingModelTest {
    @Test
    fun `disabled or non-owner source never fetches and clears prior state`() = runBlocking {
        val source = FakeSource(enabled = false)
        val model = TraktContinueWatchingModel(source)

        assertTrue(model.refresh(allowOwner = true).items.isEmpty())
        assertEquals(0, source.fetches)
        source.enabled = true
        source.response = Result.success(listOf(item("tt1")))
        assertEquals(listOf("tt1"), model.refresh(true).items.map(MetaItem::id))
        assertTrue(model.refresh(allowOwner = false).items.isEmpty())
    }

    @Test
    fun `late account A response cannot publish into account B`() = runBlocking {
        val source = FakeSource(response = Result.success(listOf(item("tt-a"))))
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        source.beforeReturn = { entered.complete(Unit); release.await() }
        val model = TraktContinueWatchingModel(source)
        val pending = async { model.refresh(true) }
        entered.await()
        source.epoch = 2L
        release.complete(Unit)

        assertTrue(pending.await().items.isEmpty())
        source.beforeReturn = null
        source.response = Result.success(listOf(item("tt-b")))
        assertEquals(listOf("tt-b"), model.refresh(true).items.map(MetaItem::id))
    }

    @Test
    fun `failure retains successful snapshot for same account`() = runBlocking {
        var clock = 0L
        val source = FakeSource(response = Result.success(listOf(item("tt1"))))
        val model = TraktContinueWatchingModel(source) { clock }
        assertEquals(listOf("tt1"), model.refresh(true).items.map(MetaItem::id))
        clock += 301_000L
        source.response = Result.failure(IllegalStateException("offline"))
        assertEquals(listOf("tt1"), model.refresh(true).items.map(MetaItem::id))
    }

    @Test
    fun `fold rejects zero invalid and near-complete progress and keeps newest duplicate`() {
        val rows = listOf(
            movie("tt1111111", progress = 0, pausedAt = "2026-10-01T12:00:00Z"),
            movie("tt2222222", progress = 98, pausedAt = "2026-10-01T12:00:00Z"),
            movie("tt3333333", progress = 25, pausedAt = "2026-10-01T10:00:00Z"),
            movie("tt3333333", progress = 45, pausedAt = "2026-10-01T11:00:00Z"),
        )
        val seeds = foldTraktContinueWatching(rows)

        assertEquals(1, seeds.size)
        assertEquals("tt3333333", seeds.single().id)
        assertEquals(45f, seeds.single().progress)
    }

    @Test
    fun `episode uses show identity and preserves typed episode coordinates`() {
        val row = JSONObject().apply {
            put("type", "episode"); put("progress", 33); put("paused_at", "2026-10-01T12:00:00Z")
            put("show", JSONObject().put("title", "Show").put("ids", JSONObject().put("tmdb", 42)))
            put("episode", JSONObject().put("season", 0).put("number", 4).put("title", "Special"))
        }
        val seed = foldTraktContinueWatching(listOf(row)).single()

        assertEquals(MediaType.SERIES, seed.type)
        assertEquals("tmdb:tv:42", seed.id)
        assertEquals(0, seed.season)
        assertEquals(4, seed.episode)
    }

    @Test
    fun `distinct Trakt row remains read only and native row remains untouched`() {
        val native = Catalog("continue", "Continue Watching", listOf(item("tt-native")))
        val rows = withTraktContinueWatchingRail(listOf(native), listOf(item("tt-trakt")))

        assertEquals(listOf("continue", TRAKT_CONTINUE_WATCHING_CATALOG_ID), rows.map { it.id })
        assertFalse(rows.first().readOnly)
        assertTrue(rows.last().readOnly)
    }

    private class FakeSource(
        var epoch: Long? = 1L,
        var enabled: Boolean = true,
        var response: Result<List<MetaItem>> = Result.success(emptyList()),
    ) : TraktContinueWatchingSource {
        var fetches = 0
        var beforeReturn: (suspend () -> Unit)? = null
        override fun sessionEpoch(): Long? = epoch
        override fun isEnabled(): Boolean = enabled
        override suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>> {
            fetches += 1
            beforeReturn?.invoke()
            return response
        }
    }

    private fun item(id: String) = MetaItem(id, MediaType.MOVIE, id)

    private fun movie(id: String, progress: Number, pausedAt: String) = JSONObject().apply {
        put("type", "movie"); put("progress", progress); put("paused_at", pausedAt)
        put("movie", JSONObject().put("title", id).put("ids", JSONObject().put("imdb", id)))
    }
}
