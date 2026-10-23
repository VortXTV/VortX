package com.vortx.android.engine

import com.vortx.android.model.MediaType
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Library keeps every title watched or started unless the viewer removed it after its last watch. */
class NativePreviouslyWatchedTest {
    private fun row(meta: String, type: String, at: Long, video: String? = null, name: String? = null) =
        JSONObject().put("metaId", meta).put("type", type).put("updatedAt", at).put("offsetMs", 0).put("durationMs", 0)
            .put("timesWatched", 0).put("watched", true).apply {
                video?.let { put("videoId", it) }
                name?.let { put("name", it) }
            }

    @Test fun `watched and started titles join the Library newest first unless saved or removed`() {
        val playback = JSONObject()
            .put("continueWatching", JSONArray().put(row("tt-naruto", "series", 1_800, "tt-naruto:1:49", "Naruto")))
            .put("history", JSONArray()
                .put(row("tt-naruto", "series", 1_700, "tt-naruto:1:48", "Naruto"))
                .put(row("tt-movie", "movie", 1_500, name = "Movie"))
                .put(row("tt-saved", "movie", 1_900, name = "Saved"))
                .put(row("tt-removed", "movie", 1_200, name = "Removed"))
                .put(row("tt-rewatched", "movie", 1_600, name = "Rewatched"))
                .put(row("tt-anime", "anime", 1_400, name = "Anime"))
                .put(row("", "movie", 1_000)).put(row("tt-untyped", "", 1_000)))
        val removals = mapOf("movie:tt-removed" to 1_300L, "movie:tt-rewatched" to 1_550L, "anime:tt-anime" to 1_450L)
        val titles = NativePreviouslyWatched.titles(playback, setOf("tt-saved")) { type, id -> removals["$type:$id"] }
        assertEquals(listOf("tt-naruto", "tt-rewatched", "tt-movie"), titles.map { it.id })
        assertEquals(MediaType.SERIES, titles[0].type)
        assertEquals("Naruto", titles[0].name)
        // The removal record is keyed by the engine's own type, even one the app shows as a movie.
        assertTrue(titles.none { it.id == "tt-anime" || it.id == "tt-removed" })
        assertTrue(NativePreviouslyWatched.titles(JSONObject(), emptySet()) { _, _ -> null }.isEmpty())
        assertEquals("anime", NativePreviouslyWatched.type(playback, "tt-anime"))
        assertEquals(null, NativePreviouslyWatched.type(playback, "tt-unknown"))
    }
}
