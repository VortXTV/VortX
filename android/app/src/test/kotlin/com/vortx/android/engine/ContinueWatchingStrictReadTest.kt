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
