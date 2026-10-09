package com.vortx.android.home

import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SimklContinueWatchingModelTest {
    private val oldAt = "2026-10-08T10:00:00Z"
    private val newAt = "2026-10-09T10:00:00Z"

    @Test fun `paused episode wins over next episode without inventing offset`() {
        val paused = pause("tt1111111", 1, 2).put("paused_at", oldAt)
        val next = watching("tt1111111", 1, 3).put("last_watched_at", newAt)
        val seed = foldSimklContinueWatching(listOf(paused), listOf(next)).single()
        assertEquals(2, seed.preferredEpisode?.episode)
        assertEquals(35f, seed.progress)
        assertEquals(parseContinueWatchingActivity(oldAt), seed.activityAtMillis)
        val nextOnly = foldSimklContinueWatching(emptyList(), listOf(next)).single()
        assertNull(nextOnly.progress)
        assertEquals(3, nextOnly.preferredEpisode?.episode)
        assertNull(card(nextOnly).resumeSeconds)
    }

    @Test fun `caught-up held dropped and movie watchlist entries do not become next-to-watch cards`() {
        val rows = listOf(watching("tt1111111", 1, 2).put("next_to_watch", JSONObject.NULL),
            watching("tt2222222", 1, 2).put("status", "hold"), watching("tt3333333", 1, 2).put("status", "dropped"),
            JSONObject().put("status", "watching").put("movie", media("tt4444444", 44)))
        assertTrue(foldSimklContinueWatching(emptyList(), rows).isEmpty())
        val moviePause = JSONObject().put("type", "movie").put("progress", 52.5).put("watched_at", newAt).put("movie", media("tt4444444", 44))
        val seed = foldSimklContinueWatching(listOf(moviePause), rows).single()
        assertEquals(52.5f, seed.progress)
        assertEquals(parseContinueWatchingActivity(newAt), seed.activityAtMillis)
        assertNull(seed.preferredEpisode)
    }

    @Test fun `transitive external aliases dedupe show anime and numeric string tmdb identities`() {
        val a = watching("tt1111111", 1, 2, simkl = 11)
        val bridge = watching("tt1111111", 1, 3, simkl = 12)
        bridge.getJSONObject("show").getJSONObject("ids").put("tmdb", "42")
        val c = watching("", 1, 4, simkl = 13)
        c.getJSONObject("show").getJSONObject("ids").put("tmdb", 42)
        val anime = JSONObject(c.toString()).put("anime", c.getJSONObject("show")); anime.remove("show")
        val seeds = foldSimklContinueWatching(emptyList(), listOf(a, bridge, anime))
        assertEquals(1, seeds.size)
    }

    @Test fun `unknown clock remains unknown while invalid progress never creates pause`() {
        val paused = pause("tt1111111", 1, 2).put("paused_at", "invalid")
        assertNull(foldSimklContinueWatching(listOf(paused), emptyList()).single().activityAtMillis)
        listOf(0, 95, 100, -1).forEach { progress ->
            assertTrue(foldSimklContinueWatching(listOf(JSONObject(paused.toString()).put("progress", progress)), emptyList()).isEmpty())
        }
    }

    @Test fun `activities first throttle and exact prior cursor govern terminal deltas`() = runBlocking {
        var clock = 0L
        val source = FakeSource()
        source.library = payload(watching("tt1111111", 1, 2))
        val model = model(source) { clock }
        assertEquals(listOf("tt1111111"), model.refresh(true).items.map { it.id })
        assertEquals("/sync/activities", source.calls.first())
        val initialCalls = source.calls.size
        model.refresh(true)
        assertEquals(initialCalls, source.calls.size)
        clock += 300_001
        source.activities = activities(newAt, watching = newAt)
        source.library = payload(watching("tt1111111", 1, 2).put("status", "hold"))
        assertTrue(model.refresh(true).items.isEmpty())
        assertEquals(newAt, model.acceptedCursor())
        assertTrue(source.calls.any { "date_from=2026-10-08T10%3A00%3A00Z" in it })
    }

    @Test fun `removed snapshot prunes cached titles and valid empty snapshot clears pauses`() = runBlocking {
        var clock = 0L
        val source = FakeSource()
        source.library = payload(watching("tt1111111", 1, 2))
        val second = pause("tt2222222", 1, 2).also { it.getJSONObject("show").getJSONObject("ids").put("simkl", 22) }
        source.playback = JSONArray().put(second).toString()
        val model = model(source) { clock }
        assertEquals(2, model.refresh(true).items.size)
        clock += 300_001
        source.activities = activities(newAt, removed = newAt)
        source.ids = JSONObject().toString(); source.playback = "[]"
        assertTrue(model.refresh(true).items.isEmpty())
        assertTrue(source.calls.any { "extended=simkl_ids_only" in it })
        assertEquals(newAt, model.acceptedCursor())
    }

    @Test fun `failed playback leg retains accepted complete snapshot and activity cursor`() = runBlocking {
        var clock = 0L
        val source = FakeSource()
        source.library = payload(watching("tt1111111", 1, 2))
        val model = model(source) { clock }
        val original = model.refresh(true).items
        clock += 300_001
        source.activities = activities(newAt, watching = newAt)
        source.library = payload(watching("tt1111111", 1, 2).put("status", "dropped"))
        source.failPlayback = true
        val failed = model.refresh(true)
        assertEquals(original, failed.items)
        assertNotNull(failed.errorMessage)
        assertEquals(oldAt, model.acceptedCursor())
        clock += 300_001; source.failPlayback = false
        assertTrue(model.refresh(true).items.isEmpty())
        assertEquals(newAt, model.acceptedCursor())
    }

    @Test fun `unchanged activities still reconciles playback expiry after throttle`() = runBlocking {
        var clock = 0L
        val source = FakeSource(playback = JSONArray().put(pause("tt1111111", 1, 2)).toString())
        val model = model(source) { clock }
        assertEquals(1, model.refresh(true).items.size)
        val libraryCalls = source.calls.count { it.startsWith("/sync/all-items") }
        clock += 300_001; source.playback = "[]"
        assertTrue(model.refresh(true).items.isEmpty())
        assertEquals(libraryCalls, source.calls.count { it.startsWith("/sync/all-items") })
    }

    @Test fun `retired session and explicit clear cannot publish late provider results`() = runBlocking {
        listOf(false, true).forEach { retireByClear ->
            val source = FakeSource(library = payload(watching("tt1111111", 1, 2)))
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            source.beforePlayback = { entered.complete(Unit); release.await() }
            val model = model(source) { 0 }
            val pending = async { model.refresh(true) }
            entered.await()
            if (retireByClear) model.clear() else source.epoch = 2
            release.complete(Unit)
            assertTrue(pending.await().items.isEmpty())
            assertNull(model.acceptedCursor())
        }
    }

    @Test fun `unknown owner or disconnected source never fetches`() = runBlocking {
        val source = FakeSource()
        val model = model(source) { 0 }
        assertTrue(model.refresh(false).items.isEmpty()); assertTrue(source.calls.isEmpty())
        source.epoch = null
        assertTrue(model.refresh(true).items.isEmpty()); assertTrue(source.calls.isEmpty())
    }

    @Test fun `documented marker and separate info produce real next episode and caught-up guard wins`() {
        val row = watching("tt1111111", 8, 3)
        row.getJSONObject("next_to_watch_info").put("title", "Actual next title")
        val seed = foldSimklContinueWatching(emptyList(), listOf(row)).single()
        assertEquals(8, seed.preferredEpisode?.season); assertEquals(3, seed.preferredEpisode?.episode)
        assertEquals("Actual next title", seed.episodeName); assertNull(seed.progress)
        assertTrue(foldSimklContinueWatching(emptyList(), listOf(JSONObject(row.toString()).put("next_to_watch", JSONObject.NULL))).isEmpty())
        assertNull(foldSimklContinueWatching(emptyList(), listOf(JSONObject(row.toString()).put("next_to_watch", "S08E04"))).single().preferredEpisode)
        val anime = JSONObject(row.toString()).put("anime_type", "tv")
        anime.getJSONObject("next_to_watch_info").remove("season")
        assertNull(foldSimklContinueWatching(emptyList(), listOf(anime)).single().preferredEpisode)
        assertNotNull(foldSimklContinueWatching(emptyList(), listOf(anime.put("next_to_watch", "14"))).single().unavailableMessage())
        assertTrue(foldSimklContinueWatching(emptyList(), listOf(JSONObject(anime.toString()).put("anime_type", "movie"))).isEmpty())
    }

    @Test fun `valid new empty account with null activities accepts complete empty snapshot`() = runBlocking {
        var clock = 0L
        val source = FakeSource().also { it.activities = JSONObject().put("all", JSONObject.NULL).toString() }
        val model = model(source) { clock }
        assertNull(model.refresh(true).errorMessage)
        assertTrue(model.refresh(true).items.isEmpty())
        clock += 300_001
        source.activities = activities(newAt, watching = newAt); source.library = payload(watching("tt1111111", 1, 2))
        // This activity also introduces a removal cursor; its full IDs snapshot must agree with the new library.
        source.ids = source.library
        assertEquals(1, model.refresh(true).items.size)
        assertFalse(source.calls.any { "date_from=null" in it || "date_from=&" in it })
    }

    @Test fun `fractional boolean string overflow and partial mapped coordinates never become playable episodes`() {
        val malformed: List<Any> = listOf(3.5, true, "3", Long.MAX_VALUE, -1)
        malformed.forEach { value ->
            val raw = pause("tt1111111", 3, 8).also { it.getJSONObject("episode").put("season", value) }
            assertNull(foldSimklContinueWatching(listOf(raw), emptyList()).single().preferredEpisode)
            val mapped = pause("tt1111111", 1, 14).put("anime", media("tt1111111", 11)).also {
                it.remove("show"); it.getJSONObject("episode").put("tvdb_season", 2).put("tvdb_number", value)
            }
            val seed = foldSimklContinueWatching(listOf(mapped), emptyList()).single()
            assertNull(seed.preferredEpisode); assertNotNull(seed.unavailableMessage())
            val next = watching("tt1111111", 3, 8).also { it.getJSONObject("next_to_watch_info").put("season", value) }
            assertNull(foldSimklContinueWatching(emptyList(), listOf(next)).single().preferredEpisode)
        }
        val fractionalNumber = pause("tt1111111", 3, 8).also { it.getJSONObject("episode").put("number", 8.9) }
        assertNull(foldSimklContinueWatching(listOf(fractionalNumber), emptyList()).single().preferredEpisode)
        val partial = pause("tt1111111", 1, 14).also { it.getJSONObject("episode").put("tvdb_season", 2) }
        assertNull(foldSimklContinueWatching(listOf(partial), emptyList()).single().preferredEpisode)
        val integral = pause("tt1111111", 1, 14).also { it.getJSONObject("episode").put("tvdb_season", 2.0).put("tvdb_number", 2.0) }
        assertEquals(com.vortx.android.model.PreferredEpisode(2, 2), foldSimklContinueWatching(listOf(integral), emptyList()).single().preferredEpisode)
        assertNull(foldSimklContinueWatching(emptyList(), listOf(watching("tt1111111", 3, 8)
            .put("next_to_watch", "S99999999999999999999E8"))).single().preferredEpisode)
    }

    @Test fun `genuine SIMKL only and anime pause with unknown season remain explicit unavailable titles`() {
        val sourceOnly = watching("", 1, 2, simkl = 55)
        val seed = foldSimklContinueWatching(emptyList(), listOf(sourceOnly)).single()
        assertEquals("simkl:series:55", seed.id); assertNotNull(seed.unavailableMessage())
        assertNull(card(seed).resumeSeconds); assertNotNull(card(seed).continueWatchingUnavailableMessage)
        val anime = pause("tt1111111", 1, 2).also { it.getJSONObject("episode").remove("season") }
        val paused = foldSimklContinueWatching(listOf(anime), emptyList()).single()
        assertEquals(35f, paused.progress); assertNull(paused.preferredEpisode); assertNotNull(paused.unavailableMessage())
    }

    @Test fun `terminal delta retires old watching alias even if source key changed`() {
        val watching = watching("tt1111111", 1, 2, simkl = 11)
        val dropped = watching("tt1111111", 1, 2, simkl = 22).put("status", "dropped")
        val merged = mergeSimklLibraryDelta(mapOf("shows|11" to watching), mapOf("shows|22" to dropped))
        assertEquals(setOf("shows|22"), merged.keys)
        assertTrue(foldSimklContinueWatching(emptyList(), merged.values.toList()).isEmpty())
    }

    @Test fun `late artwork completion cannot publish after profile or session retirement`() = runBlocking {
        listOf(false, true).forEach { profileRetired ->
            val source = FakeSource(library = payload(watching("tt1111111", 1, 2)))
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val model = SimklContinueWatchingModel(source, { 0 }) { seed -> entered.complete(Unit); release.await(); card(seed) }
            val pending = async { model.refresh(true) }; entered.await()
            if (profileRetired) model.clear() else source.epoch = 2
            release.complete(Unit)
            assertTrue(pending.await().items.isEmpty()); assertNull(model.acceptedCursor())
        }
    }

    @Test fun `anime playback uses exact TVDB mapping and never AniDB coordinates as engine hint`() {
        val anime = pause("tt1111111", 1, 14)
        anime.put("anime", anime.getJSONObject("show").put("anime_type", "tv")); anime.remove("show")
        anime.getJSONObject("episode").put("tvdb_season", 2).put("tvdb_number", 2)
        val mapped = foldSimklContinueWatching(listOf(anime), emptyList()).single()
        assertEquals(2, mapped.preferredEpisode?.season); assertEquals(2, mapped.preferredEpisode?.episode)
        anime.getJSONObject("episode").remove("tvdb_season"); anime.getJSONObject("episode").remove("tvdb_number")
        val unknown = foldSimklContinueWatching(listOf(anime), emptyList()).single()
        assertNull(unknown.preferredEpisode); assertNotNull(unknown.unavailableMessage()); assertEquals(35f, unknown.progress)
        anime.getJSONObject("anime").put("anime_type", "movie")
        val movie = foldSimklContinueWatching(listOf(anime), emptyList()).single()
        assertEquals(com.vortx.android.model.MediaType.MOVIE, movie.type); assertNull(movie.preferredEpisode)
        assertNull(movie.unavailableMessage())
    }

    @Test fun `failed activity or library or removal snapshot retains every accepted leg`() = runBlocking {
        listOf("/sync/activities", "/sync/all-items?next_watch_info", "/sync/all-items?extended").forEach { failedPath ->
            var clock = 0L
            val source = FakeSource(library = payload(watching("tt1111111", 1, 2)))
            val model = model(source) { clock }; val accepted = model.refresh(true).items
            clock += 300_001; source.activities = activities(newAt, watching = newAt, removed = newAt)
            source.failPrefix = failedPath
            val failed = model.refresh(true)
            assertEquals(accepted, failed.items); assertNotNull(failed.errorMessage); assertEquals(oldAt, model.acceptedCursor())
        }
    }

    private fun model(source: FakeSource, clock: () -> Long) = SimklContinueWatchingModel(source, clock, ::card)
    private fun card(seed: SimklContinueWatchingSeed) = simklContinueWatchingPresentation(seed, traktContinueWatchingFallback(seed.artworkSeed()))

    private inner class FakeSource(
        var epoch: Long? = 1, var library: String = "{}", var playback: String = "[]",
    ) : SimklContinueWatchingSource {
        val calls = mutableListOf<String>()
        var activities = activities(oldAt)
        var ids = "{}"
        var failPlayback = false
        var failPrefix: String? = null
        var beforePlayback: (suspend () -> Unit)? = null
        override fun sessionEpoch() = epoch
        override suspend fun get(path: String, expectedEpoch: Long): Result<String> {
            calls += path
            if (failPrefix?.let(path::startsWith) == true) return Result.failure(IllegalStateException("offline"))
            return when {
                path == "/sync/activities" -> Result.success(activities)
                "extended=simkl_ids_only" in path -> Result.success(ids)
                path.startsWith("/sync/all-items") -> Result.success(library)
                path.startsWith("/sync/playback") -> {
                    beforePlayback?.invoke()
                    if (failPlayback) Result.failure(IllegalStateException("offline")) else Result.success(playback)
                }
                else -> error("Unexpected read $path")
            }
        }
    }

    private fun activities(all: String, watching: String = oldAt, removed: String = oldAt) = JSONObject().put("all", all)
        .put("tv_shows", JSONObject().put("watching", watching).put("removed_from_list", removed)).toString()
    private fun payload(vararg rows: JSONObject) = JSONObject().put("shows", JSONArray(rows.toList())).toString()
    private fun media(imdb: String, simkl: Int) = JSONObject().put("title", "Fixture $simkl")
        .put("ids", JSONObject().put("imdb", imdb).put("simkl", simkl))
    private fun watching(imdb: String, season: Int, episode: Int, simkl: Int = 11) = JSONObject()
        .put("status", "watching").put("last_watched_at", oldAt).put("show", media(imdb, simkl))
        .put("next_to_watch", "S${season.toString().padStart(2, '0')}E${episode.toString().padStart(2, '0')}")
        .put("next_to_watch_info", JSONObject().put("season", season).put("episode", episode))
    private fun pause(imdb: String, season: Int, episode: Int) = JSONObject().put("type", "episode")
        .put("progress", 35).put("paused_at", oldAt).put("show", media(imdb, 11))
        .put("episode", JSONObject().put("season", season).put("number", episode))
}
