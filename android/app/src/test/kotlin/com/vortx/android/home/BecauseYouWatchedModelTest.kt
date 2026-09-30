package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
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
    fun `unwatched library titles do not become recommendation seeds`() = runBlocking {
        val seeds = mutableListOf<String>()
        val model = BecauseYouWatchedModel { seed ->
            seeds += seed.id
            listOf(item("tt-result-${seed.id}"))
        }

        model.refresh(
            continueWatching = listOf(item("tt-watched")),
            library = listOf(item("tt-saved", watched = false, progress = 0f)),
        )

        assertEquals(listOf("tt-watched"), seeds)
    }

    @Test
    fun `watch progress mutation invalidates the cached rail`() = runBlocking {
        var calls = 0
        val model = BecauseYouWatchedModel { calls += 1; listOf(item("tt-result")) }
        val first = item("tt1", progress = 0.1f)
        val second = item("tt1", progress = 0.2f)

        model.refresh(listOf(first), emptyList())
        model.refresh(listOf(second), emptyList())

        assertEquals(2, calls)
    }

    @Test
    fun `late response from an old owner cannot replace the newest owner rail`() = runBlocking {
        val oldOwnerGate = CompletableDeferred<Unit>()
        val model = BecauseYouWatchedModel { seed ->
            if (seed.id == "tt-old") oldOwnerGate.await()
            listOf(item("tt-result-${seed.id}"))
        }

        val oldRequest = async {
            model.refresh(listOf(item("tt-old")), emptyList(), ownerKey = "profile-a")
        }
        yield()
        val newResult = model.refresh(listOf(item("tt-new")), emptyList(), ownerKey = "profile-b")
        oldOwnerGate.complete(Unit)
        oldRequest.await()

        assertEquals(listOf("tt-result-tt-new"), newResult.rail?.items?.map(MetaItem::id))
        assertEquals(
            listOf("tt-result-tt-new"),
            model.refresh(listOf(item("tt-new")), emptyList(), ownerKey = "profile-b").rail?.items?.map(MetaItem::id),
        )
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

    private fun item(
        id: String,
        name: String = id,
        watched: Boolean = true,
        progress: Float = 0.5f,
    ) = MetaItem(id, MediaType.MOVIE, name, progress = progress, watched = watched)
}
