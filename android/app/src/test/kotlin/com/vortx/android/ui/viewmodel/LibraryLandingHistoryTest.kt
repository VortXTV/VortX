package com.vortx.android.ui.viewmodel

import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryLandingHistoryTest {
    @Test
    fun `history keeps an unsaved watched title and rejects a saved unwatched title`() = runBlocking {
        val owner = owner("primary", 3)
        val unsavedWatched = item("watched-unsaved", watched = true, progress = 0.8f)
        val savedUnwatched = item("saved-unwatched", watched = false, progress = null)
        val continueWatching = item("resume", watched = false, progress = 0.3f)
        val repo = HistoryRepository(
            owner = owner,
            history = listOf(unsavedWatched),
            continueWatching = listOf(continueWatching),
            savedLibrary = listOf(savedUnwatched),
        )

        val result = loadLibraryLanding(repo).getOrThrow()

        assertEquals(listOf("watched-unsaved"), result.playbackHistory.map { it.id })
        assertEquals(listOf("resume"), result.continueWatching.map { it.id })
        assertEquals(listOf("saved-unwatched"), repo.library(null).getOrThrow().items.map { it.id })
        assertFalse(result.playbackHistory.any { it.id == savedUnwatched.id })
    }

    @Test
    fun `owner drift rejects mixed history and continue watching projections`() = runBlocking {
        val owner = owner("primary", 3)
        val changedOwner = owner("secondary", 4)
        val repo = HistoryRepository(
            owner = owner,
            history = listOf(item("watched-unsaved", watched = true)),
            continueWatching = listOf(item("resume", progress = 0.3f)),
            continueWatchingOwner = changedOwner,
        )

        val result = loadLibraryLanding(repo)

        assertTrue(result.isFailure)
    }

    private class HistoryRepository(
        private val owner: ContinueWatchingOwner,
        private val history: List<MetaItem>,
        private val continueWatching: List<MetaItem>,
        private val savedLibrary: List<MetaItem> = emptyList(),
        private val continueWatchingOwner: ContinueWatchingOwner = owner,
    ) : CatalogRepository by PreviewCatalogRepository(latencyMs = 0L) {
        override fun continueWatchingOwner(): ContinueWatchingOwner = owner

        override suspend fun playbackHistorySnapshot(expectedOwner: ContinueWatchingOwner): Result<ContinueWatchingSnapshot> =
            Result.success(ContinueWatchingSnapshot(owner, history))

        override suspend fun library(requestJson: String?): Result<LibraryResult> =
            Result.success(LibraryResult(items = savedLibrary))

        override suspend fun continueWatchingSnapshot(expectedOwner: ContinueWatchingOwner): Result<ContinueWatchingSnapshot> =
            Result.success(ContinueWatchingSnapshot(continueWatchingOwner, continueWatching))
    }

    private fun owner(profileId: String, revision: Long) = ContinueWatchingOwner(
        profileId = profileId,
        accountSlot = "account.$profileId",
        principal = "principal.$profileId",
        usesEngineHistory = true,
        revision = revision,
    )

    private fun item(id: String, watched: Boolean = false, progress: Float? = null) = MetaItem(
        id = id,
        type = MediaType.MOVIE,
        name = id,
        watched = watched,
        progress = progress,
    )
}
