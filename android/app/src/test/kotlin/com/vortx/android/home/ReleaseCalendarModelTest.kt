package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class ReleaseCalendarModelTest {
    private val reference = Instant.parse("2026-08-01T00:00:00Z")

    @Test
    fun `builds soonest episode and movie inside 45 day horizon from library and watchlist`() = runBlocking {
        val payloads = mapOf(
            "series:tt-series" to JSONObject(
                """{"meta":{"name":"Show","poster":"show.jpg","videos":[
                    {"season":1,"episode":1,"released":"2026-07-01T00:00:00Z"},
                    {"season":2,"episode":3,"thumbnail":"episode.jpg","released":"2026-08-11T00:00:00Z"},
                    {"season":2,"episode":4,"released":"2026-09-20T00:00:00Z"}
                ]}}""",
            ),
            "movie:tt-movie" to JSONObject(
                """{"meta":{"name":"Movie","poster":"movie.jpg","released":"2026-08-06T00:00:00Z"}}""",
            ),
        )
        val model = ReleaseCalendarModel { _, type, id -> payloads["${type.id}:$id"] }

        val result = model.refresh(
            library = listOf(item("tt-series", MediaType.SERIES)),
            watchlist = listOf(item("tt-movie", MediaType.MOVIE)),
            metaBases = listOf("https://meta.example"),
            reference = reference,
        )

        assertEquals(listOf("tt-series"), result.episodes.map { it.id })
        assertEquals("S2E3 · Aug 11", result.episodes.single().caption)
        assertEquals("episode.jpg", result.episodes.single().poster)
        assertEquals(listOf("tt-movie"), result.movies.map { it.id })
        assertEquals("Aug 6", result.movies.single().caption)
        assertTrue(result.changed)
    }

    @Test
    fun `deduplicates seeds and unchanged signature performs no second fetch`() = runBlocking {
        var calls = 0
        val model = ReleaseCalendarModel { _, _, _ ->
            calls += 1
            JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}""")
        }
        val seed = item("tt-movie", MediaType.MOVIE)

        assertTrue(model.refresh(listOf(seed), listOf(seed), listOf("https://meta.example"), reference).changed)
        assertFalse(model.refresh(listOf(seed), listOf(seed), listOf("https://meta.example"), reference).changed)
        assertEquals(1, calls)
    }

    @Test
    fun `honest first empty is cached but transient empty restores populated rails`() = runBlocking {
        var calls = 0
        var returnMeta = false
        val model = ReleaseCalendarModel { _, _, _ ->
            calls += 1
            if (returnMeta) JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}""") else null
        }
        val first = item("tt-empty", MediaType.MOVIE)

        assertFalse(model.refresh(listOf(first), emptyList(), listOf("https://meta.example"), reference).changed)
        assertFalse(model.refresh(listOf(first), emptyList(), listOf("https://meta.example"), reference).changed)
        assertEquals(1, calls)

        returnMeta = true
        val populated = model.refresh(
            listOf(item("tt-populated", MediaType.MOVIE)),
            emptyList(),
            listOf("https://meta.example"),
            reference,
        )
        assertEquals(listOf("tt-populated"), populated.movies.map { it.id })

        returnMeta = false
        val restored = model.refresh(
            listOf(item("tt-changed", MediaType.MOVIE)),
            emptyList(),
            listOf("https://meta.example"),
            reference,
        )
        assertEquals(listOf("tt-populated"), restored.movies.map { it.id })
    }

    @Test
    fun `changed profile seeds clear stale rails before replacement fetch`() = runBlocking {
        val events = mutableListOf<String>()
        val model = ReleaseCalendarModel { _, _, id ->
            events += "fetch-$id"
            JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}""")
        }
        model.refresh(listOf(item("tt-one", MediaType.MOVIE)), emptyList(), listOf("https://meta.example"), reference)
        events.clear()

        val result = model.refresh(
            library = listOf(item("tt-two", MediaType.MOVIE)),
            watchlist = emptyList(),
            metaBases = listOf("https://meta.example"),
            reference = reference,
            onInvalidated = { events += "cleared" },
        )

        assertEquals(listOf("cleared", "fetch-tt-two"), events)
        assertEquals(listOf("tt-two"), result.movies.map { it.id })
    }

    @Test
    fun `normalizes only enabled meta addon bases`() {
        val bases = upcomingMetaBases(
            listOf(
                addon("https://one.example/config/manifest.json", providesMeta = true),
                addon("https://two.example/manifest.json/?token=x", providesMeta = true),
                addon("https://off.example/manifest.json", providesMeta = true, disabled = true),
                addon("https://streams.example/manifest.json", providesMeta = false),
            ),
        )

        assertEquals(listOf("https://one.example/config", "https://two.example"), bases)
    }

    @Test
    fun `rails follow top picks and replace rather than duplicate`() {
        val rows = listOf(
            Catalog("continue", "Continue Watching", listOf(item("tt-cw", MediaType.MOVIE))),
            Catalog(TOP_PICKS_CATALOG_ID, "Top Picks for you", listOf(item("tt-pick", MediaType.MOVIE))),
            Catalog("popular", "Popular", listOf(item("tt-popular", MediaType.MOVIE))),
        )
        val first = withReleaseCalendarRails(
            rows,
            listOf(item("tt-episode", MediaType.SERIES)),
            listOf(item("tt-movie", MediaType.MOVIE)),
        )
        val second = withReleaseCalendarRails(
            first,
            listOf(item("tt-new-episode", MediaType.SERIES)),
            emptyList(),
        )

        assertEquals(
            listOf("continue", TOP_PICKS_CATALOG_ID, UPCOMING_EPISODES_CATALOG_ID, "popular"),
            second.map { it.id },
        )
        assertEquals(listOf("tt-new-episode"), second[2].items.map { it.id })
    }

    private fun item(id: String, type: MediaType) = MetaItem(id, type, id)

    private fun addon(url: String, providesMeta: Boolean, disabled: Boolean = false) = InstalledAddon(
        transportUrl = url,
        name = url,
        providesMeta = providesMeta,
        isDisabled = disabled,
        rawDescriptorJson = "{}",
    )
}
