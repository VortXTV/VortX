package com.vortx.android.catalog

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.*
import org.junit.Test

class CollectionNeighborsTest {
    private val parts = (1..4).map { MetaItem("tmdb:$it", MediaType.MOVIE, "Part $it") }
    private fun collection(current: String?, dated: Set<String> = parts.take(3).map { it.id }.toSet()) =
        CollectionClient.MovieCollection(1, "Collection", parts, current, dated)

    @Test fun exactCurrentIdentityChoosesAdjacentDatedParts() {
        assertEquals(parts[0] to parts[2], collection("tmdb:2").releaseNeighbors())
        assertEquals(null to parts[1], collection("tmdb:1").releaseNeighbors())
        assertEquals(parts[1] to null, collection("tmdb:3").releaseNeighbors())
    }

    @Test fun unknownOrUndatedCurrentCannotInventNeighbors() {
        listOf(null, "tmdb:99", "tmdb:4", "tt2").forEach {
            assertEquals(null to null, collection(it).releaseNeighbors())
        }
        assertEquals(null to null, collection("tmdb:2", emptySet()).releaseNeighbors())
        assertEquals(null to null, collection("tmdb:2", setOf("tmdb:2")).releaseNeighbors())
    }

    @Test fun malformedAndImpossibleDatesDoNotParticipateInChronology() {
        listOf("", "TBA", "2026", "2026-9-1", "2026-02-30", "2026-13-01", "2026-09-01T00:00:00Z")
            .forEach { assertFalse(it, CollectionClient.hasReleaseDate(it)) }
        assertTrue(CollectionClient.hasReleaseDate("2024-02-29"))
        assertTrue(CollectionClient.hasReleaseDate("2026-09-11"))
    }
}
