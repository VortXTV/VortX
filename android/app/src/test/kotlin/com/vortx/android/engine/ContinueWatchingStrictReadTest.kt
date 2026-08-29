package com.vortx.android.engine

import com.vortx.android.data.ContinueWatchingDismissal
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class ContinueWatchingStrictReadTest {
    @Test
    fun `valid items snapshot is confirmation grade`() {
        val result = EngineState.parseContinueWatchingStrict(
            """{"items":[{"_id":"tt1","type":"series","name":"One"}]}""",
        )

        assertTrue(result.isSuccess)
        assertEquals("tt1", result.getOrThrow().single().id)
        assertEquals(MediaType.SERIES, result.getOrThrow().single().type)
    }

    @Test
    fun `literal null malformed and missing items all fail closed`() {
        assertTrue(EngineState.parseContinueWatchingStrict("null").isFailure)
        assertTrue(EngineState.parseContinueWatchingStrict("not-json").isFailure)
        assertTrue(EngineState.parseContinueWatchingStrict("{}").isFailure)
        assertTrue(EngineState.parseContinueWatchingStrict("""{"items":null}""").isFailure)
    }

    @Test
    fun `undecodable item identity fails the whole confirmation read`() {
        assertTrue(
            EngineState.parseContinueWatchingStrict(
                """{"items":[{"_id":"tt1","type":"movie"},{"name":"Hidden identity"}]}""",
            ).isFailure,
        )
        assertTrue(
            EngineState.parseContinueWatchingStrict(
                """{"items":[{"_id":"tt1","type":"unknown"}]}""",
            ).isFailure,
        )
    }

    @Test
    fun `engine fold uses played aliases and lets newer removals suppress stale rows`() {
        val items = EngineState.parseContinueWatching(
            """{
              "items": [
                {
                  "_id": "tmdb:1396", "type": "series", "name": "Breaking Bad",
                  "poster": "https://img/new.jpg",
                  "state": {"timeOffset": 1200000, "duration": 2700000, "video_id": "tt0903747:5:16", "lastWatched": "2026-08-29T20:00:00Z"}
                },
                {
                  "_id": "imdb:tt0903747", "type": "series", "name": "Breaking Bad",
                  "poster": "https://img/old.jpg",
                  "state": {"timeOffset": 900000, "duration": 2700000, "video_id": "tt0903747:5:15", "lastWatched": "2026-08-29T19:00:00Z"}
                },
                {
                  "_id": "tmdb:tv:200", "type": "series", "name": "Breaking Bad",
                  "poster": "https://img/new.jpg",
                  "state": {"timeOffset": 300000, "duration": 2700000, "lastWatched": "2026-08-29T18:00:00Z"}
                },
                {
                  "_id": "tmdb:movie:50", "type": "movie", "name": "Removed",
                  "state": {"timeOffset": 300000, "duration": 6000000, "video_id": "tt5555555", "lastWatched": "2026-08-29T17:00:00Z"}
                },
                {
                  "_id": "tt5555555", "type": "movie", "name": "Removed", "removed": true,
                  "state": {"timeOffset": 0, "duration": 0, "lastWatched": "2026-08-29T21:00:00Z"}
                }
              ]
            }""".trimIndent(),
        )

        assertEquals(listOf("tmdb:1396", "tmdb:tv:200"), items.map { it.id })
        assertEquals(1200.0, items.first().resumeSeconds ?: 0.0, 0.001)
    }

    @Test
    fun `bare-id native deletion fails closed when media types share the id`() {
        val target = ContinueWatchingDismissal(
            owner = ContinueWatchingOwner("profile", "account", "principal", true, 7L),
            type = MediaType.MOVIE,
            id = "shared",
        )
        val items = listOf(
            MetaItem("shared", MediaType.MOVIE, "Movie"),
            MetaItem("shared", MediaType.SERIES, "Series"),
        )

        assertThrows(IllegalStateException::class.java) {
            validateContinueWatchingRemovalTarget(items, target)
        }
        assertTrue(validateContinueWatchingRemovalTarget(items.take(1), target))
    }
}
