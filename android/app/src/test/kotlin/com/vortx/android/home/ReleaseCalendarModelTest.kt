package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.ServerSocket
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.concurrent.Executors
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ReleaseCalendarModelTest {
    private val reference = Instant.parse("2026-08-01T00:00:00Z")
    private val owner = ReleaseCalendarOwner("OWNER", 1L)

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
        val model = ReleaseCalendarModel { _, type, id -> success(payloads["${type.id}:$id"]) }

        val result = model.refresh(
            owner = owner,
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
    fun `deduplicates seeds and unchanged signatures perform no second fetch`() = runBlocking {
        var calls = 0
        val model = ReleaseCalendarModel { _, _, _ ->
            calls += 1
            success(JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}"""))
        }
        val seed = item("tt-movie", MediaType.MOVIE)

        assertTrue(model.refresh(owner, listOf(seed), listOf(seed), listOf("https://meta.example"), reference).changed)
        assertFalse(model.refresh(owner, listOf(seed), listOf(seed), listOf("https://meta.example"), reference).changed)
        assertEquals(1, calls)
    }

    @Test
    fun `honest empty is cached and transient failure retains only same owner and seed`() = runBlocking {
        var calls = 0
        val emptyModel = ReleaseCalendarModel { _, _, _ ->
            calls += 1
            success(null)
        }
        val seed = item("tt-movie", MediaType.MOVIE)

        assertFalse(emptyModel.refresh(owner, listOf(seed), emptyList(), listOf("https://meta.example"), reference).changed)
        assertFalse(emptyModel.refresh(owner, listOf(seed), emptyList(), listOf("https://meta.example"), reference).changed)
        assertEquals(1, calls)

        var failing = false
        val populatedModel = ReleaseCalendarModel { _, _, _ ->
            if (failing) UpcomingMetaResponse.TransientFailure
            else success(JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}"""))
        }
        val populated = populatedModel.refresh(owner, listOf(seed), emptyList(), listOf("https://meta.example"), reference)
        failing = true
        val retained = populatedModel.refresh(
            owner,
            listOf(seed),
            emptyList(),
            listOf("https://meta.example"),
            reference.plus(1, ChronoUnit.DAYS),
        )

        assertEquals(populated.movies, retained.movies)
        assertEquals(ReleaseCalendarRailOutcome.RETAINED_AFTER_TRANSIENT_FAILURE, retained.movieOutcome)
    }

    @Test
    fun `failed refresh cannot restore a previous owner or different seed`() = runBlocking {
        var failing = false
        val model = ReleaseCalendarModel { _, _, _ ->
            if (failing) UpcomingMetaResponse.TransientFailure
            else success(JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}"""))
        }
        val seedA = item("tt-a", MediaType.MOVIE)
        model.refresh(owner, listOf(seedA), emptyList(), listOf("https://meta.example"), reference)
        failing = true

        val differentSeed = model.refresh(
            owner,
            listOf(item("tt-b", MediaType.MOVIE)),
            emptyList(),
            listOf("https://meta.example"),
            reference,
        )
        assertTrue(differentSeed.movies.isEmpty())

        val ownerB = ReleaseCalendarOwner("PROFILE-B", 2L)
        val invalidations = mutableListOf<ReleaseCalendarRefresh>()
        val differentOwner = model.refresh(
            ownerB,
            listOf(seedA),
            emptyList(),
            listOf("https://meta.example"),
            reference,
            onInvalidated = invalidations::add,
        )
        assertTrue(differentOwner.movies.isEmpty())
        assertTrue(invalidations.none { refresh -> refresh.movies.any { it.id == "tt-a" } })

        val lateOwnerA = model.refresh(owner, listOf(seedA), emptyList(), listOf("https://meta.example"), reference)
        assertEquals(ReleaseCalendarRailOutcome.STALE_OWNER_IGNORED, lateOwnerA.movieOutcome)
        assertTrue(lateOwnerA.movies.isEmpty())
    }

    @Test
    fun `episode and movie rails keep independent signatures and transient outcomes`() = runBlocking {
        var stage = 0
        val calls = mutableListOf<String>()
        val model = ReleaseCalendarModel { _, type, id ->
            calls += "${type.id}:$id"
            when {
                stage == 1 && type == MediaType.SERIES -> UpcomingMetaResponse.TransientFailure
                type == MediaType.SERIES -> success(
                    JSONObject("""{"meta":{"name":"Show","videos":[{"released":"2026-08-11T00:00:00Z"}]}}"""),
                )
                else -> success(
                    JSONObject("""{"meta":{"name":"Movie $stage","released":"2026-08-06T00:00:00Z"}}"""),
                )
            }
        }
        val series = item("tt-series", MediaType.SERIES)
        val movie = item("tt-movie", MediaType.MOVIE)
        val first = model.refresh(owner, listOf(series, movie), emptyList(), listOf("https://meta.example"), reference)
        calls.clear()

        val movieSeedChanged = model.refresh(
            owner,
            listOf(series, item("tt-movie-2", MediaType.MOVIE)),
            emptyList(),
            listOf("https://meta.example"),
            reference,
        )
        assertEquals(listOf("movie:tt-movie-2"), calls)
        assertEquals(first.episodes, movieSeedChanged.episodes)

        stage = 1
        calls.clear()
        val partialFailure = model.refresh(
            owner,
            listOf(series, item("tt-movie-2", MediaType.MOVIE)),
            emptyList(),
            listOf("https://meta.example"),
            reference.plus(1, ChronoUnit.DAYS),
        )

        assertEquals(first.episodes, partialFailure.episodes)
        assertEquals("Movie 1", partialFailure.movies.single().name)
        assertEquals(ReleaseCalendarRailOutcome.RETAINED_AFTER_TRANSIENT_FAILURE, partialFailure.episodeOutcome)
        assertEquals(ReleaseCalendarRailOutcome.UPDATED, partialFailure.movieOutcome)
        assertTrue(calls.containsAll(listOf("series:tt-series", "movie:tt-movie-2")))
    }

    @Test
    fun `bounded HTTP reader accepts a complete body smaller than its limit`() = runBlocking {
        val body = """{"meta":{"name":"Network Movie","released":"2026-08-06T00:00:00Z"}}"""
        RawBodyServer(expectedRequests = 1, body = body).use { server ->
            val result = withTimeout(8_000L) {
                ReleaseCalendarModel().refresh(
                    owner,
                    listOf(item("tt-network", MediaType.MOVIE)),
                    emptyList(),
                    listOf(server.baseUrl),
                    reference,
                )
            }

            server.awaitRequests()
            assertEquals("Network Movie", result.movies.single().name)
        }
    }

    @Test
    fun `truncated response bodies finish every request beyond semaphore capacity`() = runBlocking {
        RawBodyServer(expectedRequests = 7, body = "{\"meta\":", declaredLength = 128).use { server ->
            val model = ReleaseCalendarModel()
            val seeds = (1..7).map { item("tt-truncated-$it", MediaType.MOVIE) }

            val result = withTimeout(8_000L) {
                model.refresh(owner, seeds, emptyList(), listOf(server.baseUrl), reference)
            }

            server.awaitRequests()
            assertTrue(result.movies.isEmpty())
            assertEquals(7, server.accepted.get())
            assertEquals(ReleaseCalendarRailOutcome.PARTIAL_AFTER_TRANSIENT_FAILURE, result.movieOutcome)
        }
    }

    @Test
    fun `cancellation from a suspended fetch propagates instead of becoming a transient miss`() = runBlocking {
        val response = CompletableDeferred<UpcomingMetaResponse>()
        val enteredFetch = CompletableDeferred<Unit>()
        val model = ReleaseCalendarModel { _, _, _ ->
            enteredFetch.complete(Unit)
            response.await()
        }
        val refresh = async {
            model.refresh(
                owner,
                listOf(item("tt-cancelled", MediaType.MOVIE)),
                emptyList(),
                listOf("https://meta.example"),
                reference,
            )
        }

        enteredFetch.await()
        response.cancel(CancellationException("fetch cancelled"))

        try {
            refresh.await()
            fail("Expected the suspended fetch cancellation to propagate")
        } catch (_: CancellationException) {
            assertTrue(refresh.isCancelled)
        }
    }

    @Test
    fun `changed seeds clear only their stale rail before replacement fetch`() = runBlocking {
        val events = mutableListOf<String>()
        val model = ReleaseCalendarModel { _, _, id ->
            events += "fetch-$id"
            success(JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}"""))
        }
        model.refresh(owner, listOf(item("tt-one", MediaType.MOVIE)), emptyList(), listOf("https://meta.example"), reference)
        events.clear()

        val result = model.refresh(
            owner = owner,
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

    private fun success(payload: JSONObject?): UpcomingMetaResponse = UpcomingMetaResponse.Success(payload)

    private fun addon(url: String, providesMeta: Boolean, disabled: Boolean = false) = InstalledAddon(
        transportUrl = url,
        name = url,
        providesMeta = providesMeta,
        isDisabled = disabled,
        rawDescriptorJson = "{}",
    )

    private class RawBodyServer(
        private val expectedRequests: Int,
        body: String,
        declaredLength: Int = body.toByteArray().size,
    ) : AutoCloseable {
        private val socket = ServerSocket(0)
        private val executor = Executors.newSingleThreadExecutor()
        private val responseBody = body.toByteArray()
        val accepted = AtomicInteger(0)
        val baseUrl: String = "http://127.0.0.1:${socket.localPort}"
        private val serving = executor.submit {
            repeat(expectedRequests) {
                socket.accept().use { client ->
                    accepted.incrementAndGet()
                    client.getOutputStream().use { output ->
                        output.write(
                            ("HTTP/1.1 200 OK\r\n" +
                                "Content-Type: application/json\r\n" +
                                "Content-Length: $declaredLength\r\n" +
                                "Connection: close\r\n\r\n").toByteArray(),
                        )
                        output.write(responseBody)
                        output.flush()
                    }
                }
            }
        }

        fun awaitRequests() {
            serving.get(5, TimeUnit.SECONDS)
        }

        override fun close() {
            socket.close()
            executor.shutdownNow()
        }
    }
}
