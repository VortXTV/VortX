package com.vortx.android.ui.viewmodel

import com.vortx.android.home.ReleaseCalendarModel
import com.vortx.android.home.UpcomingMetaResponse
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class ReleaseCalendarOwnerTrackerTest {
    private val reference = Instant.parse("2026-08-01T00:00:00Z")

    @Test
    fun `ordinary refresh preserves independent rail cache while account and profile boundaries invalidate`() = runBlocking {
        val boundaryA = ReleaseCalendarBoundary("PROFILE-A", "ACCOUNT-A")
        val tracker = ReleaseCalendarOwnerTracker(boundaryA)
        val calls = mutableListOf<String>()
        val model = ReleaseCalendarModel { _, type, id ->
            calls += "${type.id}:$id"
            UpcomingMetaResponse.Success(
                if (type == MediaType.SERIES) {
                    JSONObject("""{"meta":{"videos":[{"released":"2026-08-11T00:00:00Z"}]}}""")
                } else {
                    JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}""")
                },
            )
        }
        val series = item("tt-series", MediaType.SERIES)
        val movieOne = item("tt-movie-one", MediaType.MOVIE)
        val movieTwo = item("tt-movie-two", MediaType.MOVIE)
        val initialOwner = tracker.ownerFor(boundaryA)
        model.refresh(initialOwner, listOf(series, movieOne), emptyList(), bases(), reference)
        calls.clear()

        val ordinaryCtxOwner = tracker.ownerFor(boundaryA)
        val ordinaryRefresh = model.refresh(
            ordinaryCtxOwner,
            listOf(series, movieTwo),
            emptyList(),
            bases(),
            reference,
        )

        assertEquals(initialOwner, ordinaryCtxOwner)
        assertEquals(listOf("movie:tt-movie-two"), calls)
        assertEquals(listOf("tt-series"), ordinaryRefresh.episodes.map { it.id })

        calls.clear()
        val accountOwner = tracker.ownerFor(boundaryA.copy(accountId = "ACCOUNT-B"))
        model.refresh(accountOwner, listOf(series, movieTwo), emptyList(), bases(), reference)
        assertEquals(initialOwner.generation + 1, accountOwner.generation)
        assertEquals(setOf("series:tt-series", "movie:tt-movie-two"), calls.toSet())

        calls.clear()
        val profileOwner = tracker.ownerFor(ReleaseCalendarBoundary("PROFILE-B", "ACCOUNT-B"))
        model.refresh(profileOwner, listOf(series, movieTwo), emptyList(), bases(), reference)
        assertEquals("PROFILE-B", profileOwner.profileId)
        assertEquals(accountOwner.generation + 1, profileOwner.generation)
        assertEquals(setOf("series:tt-series", "movie:tt-movie-two"), calls.toSet())
    }

    private fun item(id: String, type: MediaType) = MetaItem(id, type, id)

    private fun bases() = listOf("https://meta.example")
}
