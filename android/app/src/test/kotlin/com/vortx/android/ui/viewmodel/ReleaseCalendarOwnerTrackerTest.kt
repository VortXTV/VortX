package com.vortx.android.ui.viewmodel

import com.vortx.android.home.ReleaseCalendarModel
import com.vortx.android.home.UpcomingMetaResponse
import com.vortx.android.home.UPCOMING_EPISODES_CATALOG_ID
import com.vortx.android.home.UPCOMING_MOVIES_CATALOG_ID
import com.vortx.android.home.upcomingMetaBases
import com.vortx.android.home.withReleaseCalendarRails
import com.vortx.android.model.Catalog
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
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

    @Test
    fun `account boundary publishes cleared rails before failed library and addon acquisition`() = runBlocking {
        val boundaryA = ReleaseCalendarBoundary("PROFILE-A", "ACCOUNT-A")
        val tracker = ReleaseCalendarOwnerTracker(boundaryA)
        val model = ReleaseCalendarModel { _, type, _ ->
            UpcomingMetaResponse.Success(
                if (type == MediaType.SERIES) {
                    JSONObject("""{"meta":{"videos":[{"released":"2026-08-11T00:00:00Z"}]}}""")
                } else {
                    JSONObject("""{"meta":{"released":"2026-08-06T00:00:00Z"}}""")
                },
            )
        }
        val ownerA = tracker.ownerFor(boundaryA)
        val populated = model.refresh(
            ownerA,
            listOf(item("tt-old-series", MediaType.SERIES), item("tt-old-movie", MediaType.MOVIE)),
            emptyList(),
            bases(),
            reference,
        )
        val baseRows = listOf(Catalog("popular", "Popular", listOf(item("tt-current", MediaType.MOVIE))))
        var published = withReleaseCalendarRails(baseRows, populated.episodes, populated.movies)
        assertTrue(published.any { it.id == UPCOMING_EPISODES_CATALOG_ID })
        assertTrue(published.any { it.id == UPCOMING_MOVIES_CATALOG_ID })

        val ownerB = tracker.ownerFor(boundaryA.copy(accountId = "ACCOUNT-B"))
        val activation = model.activate(ownerB)
        if (activation.changed) {
            published = withReleaseCalendarRails(baseRows, activation.episodes, activation.movies)
        }

        val libraryResult = Result.failure<LibraryResult>(IOException("library unavailable"))
        val addonsResult = Result.failure<List<InstalledAddon>>(IOException("addons unavailable"))
        val skippedRefresh = if (libraryResult.isFailure || addonsResult.isFailure) {
            null
        } else {
            model.refresh(
                ownerB,
                libraryResult.getOrThrow().items,
                emptyList(),
                upcomingMetaBases(addonsResult.getOrThrow()),
                reference,
            )
        }

        assertNull(skippedRefresh)
        assertFalse(published.any { it.id == UPCOMING_EPISODES_CATALOG_ID })
        assertFalse(published.any { it.id == UPCOMING_MOVIES_CATALOG_ID })
        assertTrue(boundaryActivationPublishesBeforeDependencyReads(readCatalogViewModelsSource()))
    }

    private fun item(id: String, type: MediaType) = MetaItem(id, type, id)

    private fun bases() = listOf("https://meta.example")

    private fun boundaryActivationPublishesBeforeDependencyReads(source: String): Boolean {
        val body = source
            .substringAfter("private fun refreshPersonalizedRails() {")
            .substringBefore("private fun currentReleaseBoundary()")
        val activationPublish = body.indexOf(
            "if (applyReleaseCalendar(releaseCalendar.activate(owner))) publishHome()",
        )
        val libraryRead = body.indexOf("repo.library()")
        val addonRead = body.indexOf("repo.installedAddons()")
        return activationPublish >= 0 && activationPublish < libraryRead && activationPublish < addonRead
    }

    private fun readCatalogViewModelsSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/viewmodel/CatalogViewModels.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/viewmodel/CatalogViewModels.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/viewmodel/CatalogViewModels.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate CatalogViewModels.kt from ${File(".").absolutePath}")
    }
}
